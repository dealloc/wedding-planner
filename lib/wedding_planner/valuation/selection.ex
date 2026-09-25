defmodule WeddingPlanner.Valuation.Selection do
  @moduledoc """
  Which of an offer's lines count toward its total — the first half of every offer total
  (`docs/modules/offers-and-comparison.md` `CST-21`, `CST-22`, `CST-24`, `CST-40`,
  `CST-43`; `DR-41`, `DR-49`, `DR-61`, `DR-63`, `DR-64`). Pure: every answer is read
  from a `WeddingPlanner.Valuation.Snapshot`.

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

  ## The frozen selection (`CST-40`, `CST-43`, `DR-61`, `DR-63`, `DR-64`)

  Confirming an offer freezes its effective selection: which **services** are on
  (`D-27`: services, not lines). `freeze/2` is the single definition of what a
  confirmation captures — the services of the offer's category effectively wanted under
  the priority + override rule above — and the context stores one
  `WeddingPlanner.Offers.FrozenService` row per service (`snapshot.frozen_services`, rows
  with `offer_id` and `service_id`).

  **For an offer whose `status` is `:confirmed`** the frozen rows replace the category
  priorities and the overrides:

    * a service is effectively wanted iff it has a frozen row for this offer
      (`in_confirmed_scope?/3`); the offer's override rows are **ignored** (they are kept
      and resume if the offer is un-confirmed, `DR-64`), and so is every later change to
      the service's wanted priority (`CST-40`);
    * an *optional service* line is `:counted` iff its service is frozen-in, otherwise
      `:outside_scope` — `CST-43`'s greyed line with its "add to confirmed scope" action,
      which is also what a line for a service created after the confirmation gets;
    * a *mandatory* line is `:counted`, always — also for a frozen-out service (`DR-63`,
      decided by the user, see `inclusion/3`);
    * an *optional ad hoc* line follows its own `enabled` toggle, exactly as before: the
      toggle is per offer and nothing elsewhere in the category can move it, so it *is*
      the frozen state (`DR-61`; turning one on extends the committed total, `CST-43`
      case 3);
    * *included*, *not offered* and *unknown* stay `:no_charge`.

  A frozen-in service whose every line has gone stays effectively wanted, so
  `WeddingPlanner.Valuation.Gaps` reports it (`CST-43` case 4). The guest list still moves
  the committed total (`CST-41`) — that is the cost engine's business, not this module's.

  For every other status, behaviour is exactly the priority + override rule above, and
  frozen rows on such an offer (none should exist) are ignored.

  `wanted_by_selection?/3` and `ad_hoc_on?/3` below remain the only two places a
  selection is read; `Offer.total/4`, `Gaps`, `Comparison` and `Valuation.Invoices`
  follow through `effectively_wanted?/3` and `inclusion/3` with no change of their own
  (`DR-49`).
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
    * `:outside_scope` — an *optional service* line of a **confirmed** offer whose
      service is not in the frozen selection (`CST-43`, `DR-61`): it does not count;
    * `:no_charge` — *included*, *not offered* or *unknown*: €0 by its state.
  """
  @type inclusion :: :counted | :not_selected | :outside_scope | :no_charge

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

  For a **confirmed** offer (`CST-40`, `DR-61`): whether `service` is in its frozen
  selection (`in_confirmed_scope?/3`) — priorities and override rows are not consulted.
  """
  @spec effectively_wanted?(Snapshot.t(), Offer.t(), Service.t()) :: boolean()
  def effectively_wanted?(%Snapshot{} = snapshot, %Offer{} = offer, %Service{} = service) do
    wanted_by_selection?(snapshot, offer, service)
  end

  @doc """
  How `line` (a line of `offer`) takes part in the total (`CST-21`, `CST-22`, `CST-43`,
  `DR-49`, `DR-61`):

    * `:mandatory` → `:counted`, always — regardless of priority, of an "off" override
      and, on a confirmed offer, of the frozen selection (`DR-63`);
    * `:optional` with a service → `:counted` iff the service is effectively wanted
      (`effectively_wanted?/3`), else `:not_selected` — or, on a **confirmed** offer,
      `:outside_scope` (the service is not in the frozen selection);
    * `:optional` ad hoc → `:counted` iff its toggle `enabled` is on, else
      `:not_selected`;
    * `:included`, `:not_offered`, `:unknown` → `:no_charge`.

  Validity is not considered (see the moduledoc).
  """
  @spec inclusion(Snapshot.t(), Offer.t(), OfferLine.t()) :: inclusion()
  # DR-63 (decided by the user 2026-09-25, "the current is fine"): docs/ contradicts itself —
  # CST-21 says a mandatory line counts "Always", CST-43 that a new line for a service
  # outside the frozen selection does not count. CST-21 wins: a mandatory line counts on
  # every offer, a confirmed one included, even when its service is frozen-out; CST-43's
  # greyed-out rule applies to optional lines.
  def inclusion(%Snapshot{}, %Offer{}, %OfferLine{state: :mandatory}), do: :counted

  def inclusion(%Snapshot{}, %Offer{}, %OfferLine{state: state}) when state in @no_charge_states,
    do: :no_charge

  def inclusion(%Snapshot{} = snapshot, %Offer{} = offer, %OfferLine{state: :optional} = line) do
    cond do
      OfferLine.optional_ad_hoc?(line) ->
        if ad_hoc_on?(snapshot, offer, line), do: :counted, else: :not_selected

      effectively_wanted?(snapshot, offer, service!(snapshot, line)) ->
        :counted

      # CST-43, DR-61: on a confirmed offer, "not wanted" means "outside the frozen scope".
      confirmed?(offer) ->
        :outside_scope

      true ->
        :not_selected
    end
  end

  @doc "`lines/2` restricted to the lines `inclusion/3` says are `:counted`, same order."
  @spec counted_lines(Snapshot.t(), Offer.t()) :: [OfferLine.t()]
  def counted_lines(%Snapshot{} = snapshot, %Offer{} = offer) do
    snapshot
    |> lines(offer)
    |> Enum.filter(&(inclusion(snapshot, offer, &1) == :counted))
  end

  @doc """
  `CST-40`, `DR-61`: what confirming `offer` freezes — the ids of the offer's category's
  services that are effectively wanted under the **priority + override** rule
  (`CST-24`), whatever the offer's status (the frozen set of an already confirmed offer
  is never consulted), in the category's service order (`services/2`).

  The single definition of what a confirmation captures: `WeddingPlanner.Offers` stores
  one `WeddingPlanner.Offers.FrozenService` row per id, so at the moment of confirmation
  the offer's total and gaps are unchanged.
  """
  @spec freeze(Snapshot.t(), Offer.t()) :: [service_id :: term()]
  def freeze(%Snapshot{} = snapshot, %Offer{} = offer) do
    for service <- services(snapshot, offer),
        wanted_by_priority_and_overrides?(snapshot, offer, service),
        do: service.id
  end

  @doc """
  `CST-43`, `DR-61`: whether `service` is in `offer`'s confirmed scope — `offer` is
  confirmed and has a frozen row for `service` in `snapshot.frozen_services`. Always
  `false` for an offer that is not confirmed (stray rows are ignored).
  """
  @spec in_confirmed_scope?(Snapshot.t(), Offer.t(), Service.t()) :: boolean()
  def in_confirmed_scope?(%Snapshot{} = snapshot, %Offer{} = offer, %Service{} = service) do
    confirmed?(offer) and
      Enum.any?(
        snapshot.frozen_services,
        &(&1.offer_id == offer.id and &1.service_id == service.id)
      )
  end

  # -- the selection: a confirmed offer's frozen set (C5), else priority + overrides -------

  defp wanted_by_selection?(snapshot, offer, service) do
    if confirmed?(offer) do
      in_confirmed_scope?(snapshot, offer, service)
    else
      wanted_by_priority_and_overrides?(snapshot, offer, service)
    end
  end

  # CST-24: the last override row for the offer × service decides; otherwise the priority.
  defp wanted_by_priority_and_overrides?(snapshot, offer, service) do
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

  defp confirmed?(%Offer{status: status}), do: status == :confirmed

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
