defmodule WeddingPlanner.Valuation.Selection do
  @moduledoc """
  Which of an offer's lines count toward its total — the first half of every offer total
  (`docs/modules/offers-and-comparison.md` `CST-21`, `CST-22`, `CST-24`; `DR-41`,
  `DR-49`). Pure: every answer is read from a `WeddingPlanner.Valuation.Snapshot`.

  ## Effective selection (`CST-24`)

  A service is *effectively wanted* for an offer when its wanted priority is
  `:nice_to_have` or `:must_have` (`CST-03`), unless an **override** for that offer
  turns it off — or when it is `:not_wanted` and an override turns it on. So: an override
  row for the offer × service decides when there is one; otherwise the priority does.

  Override rows are read from `snapshot.overrides` as maps or structs with exactly
  `offer_id`, `service_id` and `wanted` (`true` = on for this offer, `false` = off) —
  `DR-49`. Slice C4 persists them; C3 creates no table. At most one row per
  offer × service is assumed (C4's unique index); should several match, **the last one in
  the list wins**. That is documented, not guarded.

  ## Which lines count (`CST-21`, `CST-22`, `DR-49`)

  See `inclusion/3`. In short: *mandatory* always counts — whatever the service's
  priority and even under an "off" override (the worked example: "Mandatory lines count
  regardless of the service's wanted priority"); *optional* counts when its service is
  effectively wanted, or, for an ad hoc line (no service), when its own toggle
  (`enabled`) is on; *included*, *not offered* and *unknown* never count — they
  contribute €0.

  Selection does **not** look at a line's validity: an invalid line (per-person, its
  event deleted — `XC-41`) still counts in this sense, and the cost engine turns it into a
  flagged €0 step (`XC-42`). Rejected offers are evaluated like any other.

  ## Order (`DR-41`)

  `lines/2` returns service lines in the category's service order (`sort_order`, then
  `id`), several lines of one service by `id`, then ad hoc lines by `id`. The order is
  sorted explicitly; the snapshot's own list order is never relied on (a what-if `:put`
  appends). Ids are compared with Erlang term order, so `make_ref/0` ids work.

  ## The frozen selection (`CST-40`, `CST-43`) — slice C5

  A confirmed offer's selection is frozen. When slice C5 lands, it changes what
  `effectively_wanted?/3` (and the ad hoc toggle read in `inclusion/3`) answers for a
  confirmed offer — in `wanted_by_selection?/3` and `ad_hoc_on?/3` below, the only two
  places a selection is read. `WeddingPlanner.Valuation.Gaps` goes through
  `effectively_wanted?/3` too, so it follows automatically.
  """

  alias WeddingPlanner.Categories.Service
  alias WeddingPlanner.Offers.Offer
  alias WeddingPlanner.Offers.OfferLine
  alias WeddingPlanner.Valuation.Snapshot

  @typedoc """
  How a line takes part in the offer total:

    * `:counted` — it counts (`CST-21`); the cost engine prices it;
    * `:not_selected` — an *optional* line that is off: its service is not effectively
      wanted (`CST-24`), or it is an ad hoc line whose toggle is off (`CST-22`);
    * `:no_charge` — *included*, *not offered* or *unknown*: €0 by its state.
  """
  @type inclusion :: :counted | :not_selected | :no_charge

  @no_charge_states [:included, :not_offered, :unknown]

  @doc """
  The services of `offer`'s category in the category's service order (`CST-02`:
  `sort_order`, then `id`) — the order `lines/2` and `WeddingPlanner.Valuation.Gaps`
  follow.
  """
  @spec services(Snapshot.t(), Offer.t()) :: [Service.t()]
  def services(%Snapshot{services: services}, %Offer{category_id: category_id}) do
    services
    |> Enum.filter(&(&1.category_id == category_id))
    |> Enum.sort_by(&{&1.sort_order, &1.id})
  end

  @doc """
  The lines of `offer` in `DR-41` display order: service lines in the category's service
  order, lines of one service by `id`, then ad hoc lines by `id` (see the moduledoc).

  Raises `ArgumentError` for a service line whose service is not in the snapshot: a
  what-if that deleted a service must also delete its lines (`Snapshot.apply/2` never
  cascades).
  """
  @spec lines(Snapshot.t(), Offer.t()) :: [OfferLine.t()]
  def lines(%Snapshot{} = snapshot, %Offer{id: offer_id}) do
    service_rank =
      snapshot.services
      |> Enum.sort_by(&{&1.sort_order, &1.id})
      |> Enum.with_index()
      |> Map.new(fn {service, index} -> {service.id, index} end)

    {service_lines, ad_hoc_lines} =
      snapshot.offer_lines
      |> Enum.filter(&(&1.offer_id == offer_id))
      |> Enum.split_with(&(not is_nil(&1.service_id)))

    Enum.sort_by(service_lines, &{rank!(service_rank, &1), &1.id}) ++
      Enum.sort_by(ad_hoc_lines, & &1.id)
  end

  @doc """
  `CST-24`: whether `service` is effectively wanted for `offer` — the last override row
  for this offer × service if there is one, otherwise whether its wanted priority is
  `:nice_to_have` or `:must_have`.
  """
  @spec effectively_wanted?(Snapshot.t(), Offer.t(), Service.t()) :: boolean()
  def effectively_wanted?(%Snapshot{} = snapshot, %Offer{} = offer, %Service{} = service) do
    wanted_by_selection?(snapshot, offer, service)
  end

  @doc """
  How `line` (a line of `offer`) takes part in the total (`CST-21`, `CST-22`, `DR-49`):

    * `:mandatory` → `:counted`, always — regardless of priority and of an "off"
      override;
    * `:optional` with a service → `:counted` iff the service is effectively wanted
      (`effectively_wanted?/3`), else `:not_selected`;
    * `:optional` ad hoc → `:counted` iff its toggle `enabled` is on, else
      `:not_selected`;
    * `:included`, `:not_offered`, `:unknown` → `:no_charge`.

  Validity is not considered (see the moduledoc).
  """
  @spec inclusion(Snapshot.t(), Offer.t(), OfferLine.t()) :: inclusion()
  def inclusion(%Snapshot{}, %Offer{}, %OfferLine{state: :mandatory}), do: :counted

  def inclusion(%Snapshot{}, %Offer{}, %OfferLine{state: state}) when state in @no_charge_states,
    do: :no_charge

  def inclusion(%Snapshot{} = snapshot, %Offer{} = offer, %OfferLine{state: :optional} = line) do
    on? =
      if OfferLine.optional_ad_hoc?(line) do
        ad_hoc_on?(snapshot, offer, line)
      else
        effectively_wanted?(snapshot, offer, service!(snapshot, line))
      end

    if on?, do: :counted, else: :not_selected
  end

  @doc "`lines/2` restricted to the lines `inclusion/3` says are `:counted`, same order."
  @spec counted_lines(Snapshot.t(), Offer.t()) :: [OfferLine.t()]
  def counted_lines(%Snapshot{} = snapshot, %Offer{} = offer) do
    snapshot
    |> lines(offer)
    |> Enum.filter(&(inclusion(snapshot, offer, &1) == :counted))
  end

  # -- the selection (C5 substitutes the frozen selection for confirmed offers here) ------

  defp wanted_by_selection?(snapshot, offer, service) do
    case last_override(snapshot.overrides, offer.id, service.id) do
      nil -> service.wanted_priority in [:nice_to_have, :must_have]
      %{wanted: wanted} -> wanted == true
    end
  end

  defp ad_hoc_on?(_snapshot, _offer, %OfferLine{enabled: enabled}), do: enabled == true

  # DR-49: at most one row per offer × service is assumed; if several match, the last wins.
  defp last_override(overrides, offer_id, service_id) do
    overrides
    |> Enum.filter(&(&1.offer_id == offer_id and &1.service_id == service_id))
    |> List.last()
  end

  # -- helpers ------------------------------------------------------------------------------

  defp service!(%Snapshot{services: services}, %OfferLine{service_id: service_id} = line) do
    Enum.find(services, &(&1.id == service_id)) || missing_service!(line)
  end

  defp rank!(service_rank, %OfferLine{service_id: service_id} = line) do
    case Map.fetch(service_rank, service_id) do
      {:ok, rank} -> rank
      :error -> missing_service!(line)
    end
  end

  defp missing_service!(%OfferLine{id: id, service_id: service_id}) do
    raise ArgumentError,
          "offer line #{inspect(id)} refers to service #{inspect(service_id)}, which is not " <>
            "in the snapshot (a what-if deleting a service must also delete its lines)"
  end
end
