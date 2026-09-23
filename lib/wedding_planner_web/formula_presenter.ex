defmodule WeddingPlannerWeb.FormulaPresenter do
  @moduledoc """
  Turns a `WeddingPlanner.Valuation.Formula` (typed, unrounded values) into exactly the
  input `WeddingPlannerWeb.DisplayComponents.formula/1` documents (display strings), so
  the component never has to learn about `Money.t()`, counts or rates:

      <.formula id="venue-a-total" {FormulaPresenter.present(@formula)} />

  ## Where rounding happens (`NFR-14`)

  Here, once, per displayed value: money goes through `WeddingPlannerWeb.Format.money/1`,
  the only rounding site. Each step is rounded **independently** of the others and of
  the total, so the rendered steps may not sum to the rendered total by a cent. That is
  expected; the component states it in a standing caption, and nothing here adds,
  removes or adjusts a step to reconcile it.

  ## How each typed value renders

    * `{:money, m}` — `WeddingPlannerWeb.Format.money/1` (`€ 11.726,00`, non-breaking
      space after the euro sign, `DR-17`).
    * `{:count, n}` — the integer in the app locale's number format (`1.234`).
    * `{:rate, r}` — the fraction as a percentage in the app locale, with exactly as many
      decimals as the rate has (`0.21` → `21%`, `0.055` → `5,5%`). A VAT rate is an
      input, not a computed amount, so it is never rounded.
    * `{:preset, name}` — the preset's name as is.

  A label that is a list of segments renders each segment in order and concatenates
  them; plain-string segments are literal text.
  """

  alias WeddingPlanner.Valuation.Formula
  alias WeddingPlanner.Valuation.Formula.Step
  alias WeddingPlannerWeb.Format

  @typedoc "The `formula/1` assigns this module produces (all but `:id`, which the caller picks)."
  @type assigns :: %{
          total_label: String.t(),
          total: String.t(),
          steps: [%{label: String.t(), value: String.t()}]
        }

  @doc """
  The `formula/1` assigns for `formula`: `:total_label`, `:total` and `:steps`, every
  value a display string, the steps in the formula's order.
  """
  @spec present(Formula.t()) :: assigns()
  def present(%Formula{label: label, steps: steps, total: total}) do
    %{
      total_label: label(label),
      total: value(total),
      steps: Enum.map(steps, &step/1)
    }
  end

  defp step(%Step{label: label, value: value}), do: %{label: label(label), value: value(value)}

  defp label(text) when is_binary(text), do: text
  defp label(segments) when is_list(segments), do: Enum.map_join(segments, &segment/1)

  defp segment(text) when is_binary(text), do: text
  defp segment(value), do: value(value)

  defp value({:money, %Money{} = money}), do: Format.money(money)

  defp value({:count, count}) when is_integer(count) and count >= 0 do
    {:ok, formatted} = Localize.Number.to_string(count)
    formatted
  end

  defp value({:rate, %Decimal{} = rate}) do
    normalized = Decimal.normalize(rate)

    {:ok, formatted} =
      Localize.Number.to_string(normalized,
        format: :percent,
        fractional_digits: max(0, -normalized.exp - 2)
      )

    formatted
  end

  defp value({:preset, name}) when is_binary(name), do: name
end
