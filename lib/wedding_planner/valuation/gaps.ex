defmodule WeddingPlanner.Valuation.Gaps do
  @moduledoc """
  An offer's **gaps** (`docs/modules/offers-and-comparison.md` `CST-25`; `DR-49`,
  `DR-52`): the effectively wanted services the offer does not provide. Pure. Gaps never
  add cost — they are markers, and the cost engine never reads them.

  ## When there is a gap (`DR-49`)

  For each service of the offer's category that is effectively wanted
  (`WeddingPlanner.Valuation.Selection.effectively_wanted?/3`, `CST-24`), there is a gap
  when the offer has **no line for it in a providing state** — `:included`, `:optional`
  or `:mandatory`, whether that line is counted or not. Then:

  | The service's lines                | Severity                                        | Reason         |
  |------------------------------------|-------------------------------------------------|----------------|
  | any `:not_offered`                 | `:must_have` if must-have, else `:nice_to_have` | `:not_offered` |
  | only `:unknown`                    | `:unknown` ("ask the vendor")                   | `:unknown`     |
  | none, not must-have                | `:unknown` (`CST-25`: "treated as *unknown*")   | `:no_line`     |
  | none, **must-have**                | `:must_have` — provisional, `DR-52`             | `:no_line`     |

  A *not wanted* service switched on by an override is treated like a nice-to-have.

  The severity atoms are exactly those of
  `WeddingPlannerWeb.DisplayComponents.gap_severity/1` (prominent warning, subtle
  marker, "ask the vendor"); its fourth value, `:invalid`, is for invalid lines, which are
  **not** gaps: an invalid line (`XC-41`) is still in its providing state and neither
  creates nor removes a gap — the cost breakdown flags it (`XC-42`).

  Gaps come in the category's service order (`Selection.services/2`).
  """

  alias WeddingPlanner.Categories.Service
  alias WeddingPlanner.Offers.Offer
  alias WeddingPlanner.Valuation.Selection
  alias WeddingPlanner.Valuation.Snapshot

  @typedoc "One gap of an offer (see the moduledoc's table)."
  @type gap :: %{
          service: Service.t(),
          severity: :must_have | :nice_to_have | :unknown,
          reason: :not_offered | :unknown | :no_line
        }

  @providing_states [:included, :optional, :mandatory]

  @doc "The gaps of `offer`, in service order (`CST-25`, `DR-49`, `DR-52`)."
  @spec for_offer(Snapshot.t(), Offer.t()) :: [gap()]
  def for_offer(%Snapshot{} = snapshot, %Offer{} = offer) do
    lines = Selection.lines(snapshot, offer)

    for service <- Selection.services(snapshot, offer),
        Selection.effectively_wanted?(snapshot, offer, service),
        states = for(line <- lines, line.service_id == service.id, do: line.state),
        gap = gap(service, states),
        gap != nil,
        do: gap
  end

  defp gap(service, states) do
    cond do
      Enum.any?(states, &(&1 in @providing_states)) ->
        nil

      :not_offered in states ->
        %{service: service, severity: priority_severity(service), reason: :not_offered}

      states != [] ->
        %{service: service, severity: :unknown, reason: :unknown}

      true ->
        # DR-52 (open user question — docs/ contradicts itself): CST-25 treats "no line at
        # all" as *unknown* ("ask the vendor"), but the worked example and O3 give Venue B,
        # with no Catering line, a prominent must-have warning. Provisionally O3 wins for a
        # must-have service; anything else follows CST-25. If the user sides with CST-25,
        # this becomes `severity = :unknown` (and the O3 / DR-52 tests change with it).
        severity = if service.wanted_priority == :must_have, do: :must_have, else: :unknown
        %{service: service, severity: severity, reason: :no_line}
    end
  end

  # CST-25: must-have + not offered → prominent; nice-to-have (or a not-wanted service an
  # override switched on) + not offered → subtle.
  defp priority_severity(%Service{wanted_priority: :must_have}), do: :must_have
  defp priority_severity(%Service{}), do: :nice_to_have
end
