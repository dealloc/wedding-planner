defmodule WeddingPlannerWeb.Components.OfferCostComponents do
  @moduledoc """
  The Cost card on `/offers/:id` (task 57, DR-51): composed only of the existing
  display idioms in `WeddingPlannerWeb.DisplayComponents` — `preset_selector/1`,
  `range/1`, `formula/1`, `gap_severity/1` — following the design record's "Range +
  preset selector" and "Formula expansion" patterns (`.claude/design/ui-decisions.md`
  §2).

  `cost_card/1` renders `WeddingPlannerWeb.OfferCost.build/3`'s output; it does no
  computation of its own.
  """

  use Phoenix.Component

  import WeddingPlannerWeb.DisplayComponents,
    only: [formula: 1, gap_severity: 1, preset_selector: 1, range: 1]

  @doc """
  Renders the Cost card. `:cost` is `WeddingPlannerWeb.OfferCost.build/3`'s result,
  `:preset` the currently selected preset name (`"Minimum"` | `"Likely"` | `"Maximum"`).

  `phx-change` sits on the wrapping `<.form>` around `preset_selector/1` — never on the
  bare radio inputs — so a real browser actually fires it (a bare-`<select>`
  `phx-change` is silently dropped by LiveView's JS; `Phoenix.LiveViewTest` does not
  catch that, only a real browser does).
  """
  attr :id, :string, default: "offer-cost"
  attr :cost, :map, required: true
  attr :preset, :string, required: true

  def cost_card(assigns) do
    ~H"""
    <div id={@id} class="mt-8 rounded-field border border-line bg-surface-raised p-4">
      <h2 class="text-lg font-semibold text-ink">Cost</h2>

      <.form
        for={to_form(%{}, as: :cost_preset)}
        id="offer-cost-preset-form"
        phx-change="select_cost_preset"
        class="mt-3"
      >
        <.preset_selector id="offer-cost-preset" default={@preset} />
        <p class="mt-1 text-xs text-ink-faint">
          This preset is just for this view — it is not saved, and resets to Likely on reload.
        </p>
      </.form>

      <div
        :if={not @cost.presets_present?}
        id="offer-cost-missing-preset"
        class="mt-4 text-sm text-ink-soft"
      >
        One of the stored headcount presets (Minimum, Likely, Maximum) is missing, so this
        offer's cost cannot be computed right now.
      </div>

      <div :if={@cost.presets_present?} class="mt-4 space-y-4">
        <.range
          id="offer-cost-range"
          label="Range (Minimum – Maximum)"
          minimum={@cost.range.minimum}
          maximum={@cost.range.maximum}
        />

        <.formula
          id="offer-cost-formula"
          total_label={"Total (#{@cost.selected.name})"}
          {@cost.selected.formula_assigns}
        />
      </div>

      <div :if={@cost.gaps != []} id="offer-cost-gaps" class="mt-4 flex flex-wrap gap-2">
        <.gap_severity
          :for={gap <- @cost.gaps}
          id={"offer-gap-#{gap.service.id}"}
          severity={gap.severity}
          label={gap_label(gap)}
        />
      </div>
    </div>
    """
  end

  defp gap_label(%{severity: :unknown} = gap), do: "#{gap.service.name} — ask the vendor"
  defp gap_label(gap), do: "#{gap.service.name} — not offered"
end
