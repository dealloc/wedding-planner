defmodule WeddingPlannerWeb.Components.OfferCostComponents do
  @moduledoc """
  The Cost card on `/offers/:id` (task 57, DR-51): composed only of the existing
  display idioms in `WeddingPlannerWeb.DisplayComponents` — `preset_selector/1`,
  `range/1`, `formula/1`, `gap_severity/1` — following the design record's "Range +
  preset selector" and "Formula expansion" patterns (`.claude/design/ui-decisions.md`
  §2).

  `cost_card/1` renders `WeddingPlannerWeb.OfferCost.build/3`'s output; it does no
  computation of its own.

  Task 74 (`CST-40`, `CST-41`, design record §8): `:confirmed?` swaps the formula's
  headline from "Total (<preset>)" to "Committed (<preset>)" once the offer is
  confirmed — the figure is the same live formula either way (`CST-41`: it still
  follows the guest list), only the word changes, to signal that this total is no
  longer moved by anything else in the category. The caption keeps the same
  `--color-ink-soft` treatment `formula/1`'s headline already uses; `#offer-cost-committed-label`
  is a small marker line so a real browser check and a test can both find it without
  depending on the formula's own internal markup.
  """

  use Phoenix.Component

  import WeddingPlannerWeb.DisplayComponents,
    only: [formula: 1, gap_severity: 1, preset_selector: 1, range: 1]

  @doc """
  Renders the Cost card. `:cost` is `WeddingPlannerWeb.OfferCost.build/3`'s result,
  `:selected` the id of the currently selected preset (`DR-54`; the value the selector's
  chips carry — `WeddingPlanner.Valuation.PresetChoice.find/2`'s notion of "current
  selection", never a name).

  `phx-change` sits on the wrapping `<.form>` around `preset_selector/1` — never on the
  bare radio inputs — so a real browser actually fires it (a bare-`<select>`
  `phx-change` is silently dropped by LiveView's JS; `Phoenix.LiveViewTest` does not
  catch that, only a real browser does).
  """
  attr :id, :string, default: "offer-cost"
  attr :cost, :map, required: true
  attr :selected, :any, required: true
  attr :confirmed?, :boolean, default: false

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
        <.preset_selector id="offer-cost-preset" presets={@cost.presets} selected={@selected} />
        <p class="mt-1 text-xs text-ink-faint">
          Just for this view — not saved; resets to the default preset on reload.
        </p>
      </.form>

      <div
        :if={@cost.presets == []}
        id="offer-cost-missing-preset"
        class="mt-4 text-sm text-ink-soft"
      >
        No headcount presets are stored, so this offer's cost cannot be computed right now.
      </div>

      <div :if={@cost.selected} class="mt-4 space-y-4">
        <.range
          :if={@cost.range}
          id="offer-cost-range"
          label="Range (Minimum – Maximum)"
          minimum={@cost.range.minimum}
          maximum={@cost.range.maximum}
        />

        <p
          :if={!@cost.range}
          id="offer-cost-missing-range"
          class="text-sm text-ink-soft"
        >
          No preset is set as the range low/high end — set one on the Headcount page.
        </p>

        <p
          :if={@confirmed?}
          id="offer-cost-committed-label"
          class="text-xs font-medium tracking-wide text-ink-soft uppercase"
        >
          Committed — confirmed scope is frozen (CST-40)
        </p>

        <.formula
          id="offer-cost-formula"
          total_label={cost_total_label(@confirmed?, @cost.selected.name)}
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

  defp cost_total_label(true, name), do: "Committed (#{name})"
  defp cost_total_label(false, name), do: "Total (#{name})"
end
