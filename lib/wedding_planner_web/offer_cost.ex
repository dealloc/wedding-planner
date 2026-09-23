defmodule WeddingPlannerWeb.OfferCost do
  @moduledoc """
  Builds the plain map `WeddingPlannerWeb.Components.OfferCostComponents.cost_card/1`
  renders (task 57, DR-51): the offer's total under the three stored headcount presets
  (`CST-53`'s Minimum–Maximum range, plus the single selected figure — `HC-10`/`D-31`),
  its formula (`CST-34`, `NFR-32`) and its gaps (`CST-25`).

  Pure over a `WeddingPlanner.Valuation.Snapshot` — no database access, no LiveView
  concerns. Money is only ever formatted, never built, here (`DR-18`); rounding happens
  exclusively inside `WeddingPlannerWeb.FormulaPresenter`/`WeddingPlannerWeb.Format`
  (`NFR-14`).

  ## Presets are the stored ones, looked up by name

  `snapshot.headcount_presets` is searched for exactly the three names
  `WeddingPlannerWeb.DisplayComponents.preset_selector/1` offers — `"Minimum"`,
  `"Likely"`, `"Maximum"`. W9 has no preset CRUD, so if any of the three is missing,
  `build/3` returns `presets_present?: false` and no range/selected/gaps — the caller
  renders `#offer-cost-missing-preset` instead of a figure (no fallback to
  `WeddingPlanner.Valuation.Preset.defaults/0`; G5 revisits this once presets become
  editable).
  """

  alias WeddingPlanner.Valuation.Gaps
  alias WeddingPlanner.Valuation.Offer
  alias WeddingPlanner.Valuation.Snapshot
  alias WeddingPlannerWeb.Format
  alias WeddingPlannerWeb.FormulaPresenter

  @preset_names ["Minimum", "Likely", "Maximum"]

  @typedoc "The plain map `cost_card/1` renders."
  @type t :: %{
          presets_present?: boolean(),
          range: %{minimum: String.t(), maximum: String.t()} | nil,
          selected: %{name: String.t(), formula_assigns: FormulaPresenter.assigns()} | nil,
          gaps: [Gaps.gap()]
        }

  @doc """
  Builds the Cost card's data for the offer `offer_id` in `snapshot`, under the stored
  preset named `preset_name` (one of `"Minimum"`, `"Likely"`, `"Maximum"`).

  Raises `ArgumentError` if no offer with `offer_id` is in `snapshot.offers` — the
  caller (`WeddingPlannerWeb.Live.OfferLive`) always has a loaded offer, so this can
  only happen through a programming error, not a missing/deleted-offer race (the offer
  page itself handles that via the `:offer` `{:deleted, id}` broadcast).
  """
  @spec build(Snapshot.t(), term(), String.t()) :: t()
  def build(%Snapshot{} = snapshot, offer_id, preset_name) when is_binary(preset_name) do
    offer =
      Enum.find(snapshot.offers, &(&1.id == offer_id)) ||
        raise ArgumentError, "offer #{inspect(offer_id)} is not in the snapshot"

    presets = Map.new(@preset_names, &{&1, find_preset(snapshot, &1)})

    if Enum.all?(@preset_names, &presets[&1]) do
      minimum = Offer.total(snapshot, offer, presets["Minimum"])
      maximum = Offer.total(snapshot, offer, presets["Maximum"])
      selected_preset = Map.fetch!(presets, preset_name)
      selected_formula = Offer.total(snapshot, offer, selected_preset)

      %{
        presets_present?: true,
        range: %{minimum: money(minimum), maximum: money(maximum)},
        selected: %{
          name: preset_name,
          formula_assigns: FormulaPresenter.present(selected_formula)
        },
        gaps: Gaps.for_offer(snapshot, offer)
      }
    else
      %{presets_present?: false, range: nil, selected: nil, gaps: Gaps.for_offer(snapshot, offer)}
    end
  end

  defp find_preset(snapshot, name), do: Enum.find(snapshot.headcount_presets, &(&1.name == name))

  defp money(%WeddingPlanner.Valuation.Formula{total: {:money, money}}), do: Format.money(money)
end
