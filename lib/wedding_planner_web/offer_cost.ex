defmodule WeddingPlannerWeb.OfferCost do
  @moduledoc """
  Builds the plain map `WeddingPlannerWeb.Components.OfferCostComponents.cost_card/1`
  renders (task 57/60, `DR-51`): the offer's total under a chosen stored headcount
  preset, plus `CST-53`'s Minimum–Maximum range, its formula (`CST-34`, `NFR-32`) and
  its gaps (`CST-25`).

  Task 74 (`CST-43`, `DR-64`) adds two more fields, both derived from the same snapshot
  with no extra database access: `:line_inclusions`, one `WeddingPlanner.Valuation.Selection.inclusion/3`
  result per line id, and `:in_scope_service_ids`, the `service.id`s currently in a
  confirmed offer's frozen selection (empty otherwise). `WeddingPlannerWeb.Live.OfferLive`
  uses the former to grey out an `:outside_scope` line with its "Add to confirmed scope"
  action, and the latter to word the "stays in the confirmed scope" sentence on the
  delete-line confirmation for the last line of a frozen-in service.

  Pure over a `WeddingPlanner.Valuation.Snapshot` — no database access, no LiveView
  concerns. Money is only ever formatted, never built, here (`DR-18`); rounding happens
  exclusively inside `WeddingPlannerWeb.FormulaPresenter`/`WeddingPlannerWeb.Format`
  (`NFR-14`).

  ## Presets are found by id, never by name (`DR-54`)

  `build/3`'s third argument is the **id** of the preset the caller wants the single
  figure under (typically the id a `WeddingPlannerWeb.DisplayComponents.preset_selector/1`
  chip submitted, as its string form) — never a name. `WeddingPlanner.Valuation.PresetChoice`
  is the only place this lookup happens: `PresetChoice.find/2` resolves the id against
  `snapshot.headcount_presets`, falling back to the default (likely-role) preset when
  the id is `nil`, stale, or names nothing — so a rename or a deleted selection can
  never crash or leave the card blank. `PresetChoice.range/2` builds the range from the
  minimum-/maximum-role presets specifically, low–high, regardless of which one
  actually computes the larger figure.

  `:presets` in the result is every stored preset (`snapshot.headcount_presets`, in the
  loader's sort order) as `%{id, name}` — the full set `preset_selector/1` renders as
  chips, not the three fixed defaults. When `snapshot.headcount_presets` is `[]`,
  `:selected` and `:range` are both `nil` — the caller renders `#offer-cost-missing-preset`
  (no figure at all). When presets exist but no preset holds the `:minimum` or
  `:maximum` role, `:range` alone is `nil` while `:selected` still renders — the caller
  renders `#offer-cost-missing-range` instead, beside the figure that still shows.
  Supersedes `DR-51`'s lookup by the three fixed names ("Minimum"/"Likely"/"Maximum").
  """

  alias WeddingPlanner.Valuation.Formula
  alias WeddingPlanner.Valuation.Gaps
  alias WeddingPlanner.Valuation.Offer
  alias WeddingPlanner.Valuation.PresetChoice
  alias WeddingPlanner.Valuation.Selection
  alias WeddingPlanner.Valuation.Snapshot
  alias WeddingPlannerWeb.Format
  alias WeddingPlannerWeb.FormulaPresenter

  @typedoc "The plain map `cost_card/1` renders."
  @type t :: %{
          presets: [%{id: term(), name: String.t()}],
          range: %{minimum: String.t(), maximum: String.t()} | nil,
          selected:
            %{id: term(), name: String.t(), formula_assigns: FormulaPresenter.assigns()} | nil,
          gaps: [Gaps.gap()],
          line_inclusions: %{optional(term()) => Selection.inclusion()},
          in_scope_service_ids: MapSet.t()
        }

  @doc """
  Builds the Cost card's data for the offer `offer_id` in `snapshot`, with the
  single-figure preset chosen by `selected_id` (`PresetChoice.find/2` — `nil`, a stale
  id, or `nil` when there are no stored presets at all falls back to the default,
  likely-role preset).

  Raises `ArgumentError` if no offer with `offer_id` is in `snapshot.offers` — the
  caller (`WeddingPlannerWeb.Live.OfferLive`) always has a loaded offer, so this can
  only happen through a programming error, not a missing/deleted-offer race (the offer
  page itself handles that via the `:offer` `{:deleted, id}` broadcast).
  """
  @spec build(Snapshot.t(), term(), term() | nil) :: t()
  def build(%Snapshot{} = snapshot, offer_id, selected_id) do
    offer =
      Enum.find(snapshot.offers, &(&1.id == offer_id)) ||
        raise ArgumentError, "offer #{inspect(offer_id)} is not in the snapshot"

    presets = snapshot.headcount_presets
    figure_fun = fn preset -> total_money(snapshot, offer, preset) end

    selected =
      case PresetChoice.find(presets, selected_id) do
        nil ->
          nil

        preset ->
          %{
            id: preset.id,
            name: preset.name,
            formula_assigns: FormulaPresenter.present(Offer.total(snapshot, offer, preset))
          }
      end

    range =
      case PresetChoice.range(presets, figure_fun) do
        {:ok, {low, high}} -> %{minimum: Format.money(low), maximum: Format.money(high)}
        :missing -> nil
      end

    %{
      presets: Enum.map(presets, &%{id: &1.id, name: &1.name}),
      range: range,
      selected: selected,
      gaps: Gaps.for_offer(snapshot, offer),
      line_inclusions: line_inclusions(snapshot, offer),
      in_scope_service_ids: in_scope_service_ids(snapshot, offer)
    }
  end

  # `WeddingPlannerWeb.Live.OfferLive` (task 74, `CST-43`, `DR-64`): one
  # `Selection.inclusion/3` result per line, so the caller can grey out an
  # `:outside_scope` line and offer "Add to confirmed scope" without recomputing the
  # selection itself.
  defp line_inclusions(snapshot, offer) do
    for line <- Selection.lines(snapshot, offer), into: %{} do
      {line.id, Selection.inclusion(snapshot, offer, line)}
    end
  end

  # `CST-43` case 4 (the "stays in the confirmed scope" delete-confirmation sentence):
  # every service id currently in `offer`'s frozen selection — `[]` unless it is
  # confirmed (`Selection.in_confirmed_scope?/3`).
  defp in_scope_service_ids(snapshot, offer) do
    for service <- Selection.services(snapshot, offer),
        Selection.in_confirmed_scope?(snapshot, offer, service),
        into: MapSet.new(),
        do: service.id
  end

  defp total_money(snapshot, offer, preset) do
    %Formula{total: {:money, money}} = Offer.total(snapshot, offer, preset)
    money
  end
end
