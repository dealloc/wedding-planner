defmodule WeddingPlannerWeb.MarginalCost do
  @moduledoc """
  The pure presenter for `/people/:id`'s "Marginal cost" section (`BUD-22`, `DR-81`,
  task 90): turns `WeddingPlanner.Valuation.Simulation.marginal_cost/2`'s own result
  into exactly what `WeddingPlannerWeb.Components.BudgetComponents.role_values/1` and
  `WeddingPlannerWeb.DisplayComponents.formula/1`/`preset_selector/1` need — no money
  arithmetic happens here (that already happened inside `Simulation`, `NFR-41`), only
  display, the same `WeddingPlannerWeb.BudgetOverview`/`WeddingPlannerWeb.OfferCost`
  precedent every other range figure in this app follows.

  `Simulation.marginal_cost/2` already **is** the per-role evaluation this section
  needs (unlike `/budget`, nothing here calls into `WeddingPlanner.Valuation.Budget`
  directly, and there is exactly **one** formula disclosure — not one per role — whose
  content is swapped to whichever role the preset selector or a role-value button most
  recently picked, `HC-10`).

  ## "Not counted" is `Simulation.counted_roles/1`'s own answer, never a zero-money guess

  `DR-81`'s exact wording — "one value 'under every preset' when equal — e.g. € 0,00
  for someone counted nowhere, captioned 'Not counted…'" — reads like "equal and zero"
  by itself decides the caption. It does not: a person can be genuinely **counted**
  (present in the headcount, `Simulation.counted_roles/1` names a role for them) and
  still have an exactly € 0,00 marginal cost under every role — the real fixture that
  caught this is a person invited to an event whose only headcount-dependent offer has
  an *included quantity* comfortably above the current guest count, so removing them
  changes nothing about what is billed *right now*, though they are unquestionably on
  the list. Telling that person "Not counted for any event under these presets" would
  be false. So `build/3` takes `counted?` — `Simulation.counted_roles/1`'s own answer
  for this person, the same call `INVT-04`'s B-list filter already makes — and uses
  *that*, not a zero-money check, to choose the caption; the collapsed € 0,00 value
  itself is unaffected either way (it is what it is, computed once, upstream).
  """

  alias WeddingPlanner.Guests.Person
  alias WeddingPlanner.Valuation.Simulation
  alias WeddingPlannerWeb.Format
  alias WeddingPlannerWeb.FormulaPresenter

  @not_counted_caption "Not counted for any event under these presets."

  @typedoc "Same shape as `WeddingPlannerWeb.BudgetOverview.figure/0` (`role_values/1`'s own input)."
  @type figure :: %{
          role: Simulation.role(),
          value: String.t(),
          preset_id: term(),
          preset_name: String.t(),
          money: Money.t()
        }

  @typedoc "Same shape as `WeddingPlannerWeb.BudgetOverview.ranged/0` (`role_values/1`'s own input)."
  @type ranged ::
          :missing
          | %{equal?: boolean(), minimum: figure(), likely: figure(), maximum: figure()}

  @type t :: %{
          ranged: ranged(),
          preset_options: [%{id: term(), name: String.t()}],
          default_preset_id: term() | nil,
          formulas: %{Simulation.role() => FormulaPresenter.assigns()},
          caption: String.t() | nil
        }

  @typedoc "`Simulation.marginal_cost/2`'s own result type."
  @type marginal_cost_result ::
          :missing
          | {:ok,
             %{
               minimum: Simulation.marginal(),
               likely: Simulation.marginal(),
               maximum: Simulation.marginal()
             }}

  @doc """
  Builds the section's view model from `Simulation.marginal_cost/2`'s own result, the
  viewed `person` (only for the caption's wording — `Person.plus_one?/1`,
  `Person.display_name/1` — never for a figure or a formula, both already computed) and
  `counted?` — whether `Simulation.counted_roles/1` names any role for this person (see
  the moduledoc for why this, not a zero-money check, decides the caption). `:missing`
  (a role preset unassigned — defensive since `DR-54`) yields a `:missing` `:ranged` and
  no caption; `role_values/1` renders its own notice for that case.
  """
  @spec build(marginal_cost_result(), Person.t(), boolean()) :: t()
  def build(:missing, _person, _counted?) do
    %{ranged: :missing, preset_options: [], default_preset_id: nil, formulas: %{}, caption: nil}
  end

  def build({:ok, marginals}, %Person{} = person, counted?) do
    ranged = build_ranged(marginals)

    %{
      ranged: ranged,
      preset_options: preset_options(marginals),
      default_preset_id: marginals.likely.preset.id,
      formulas:
        Map.new(marginals, fn {role, m} -> {role, FormulaPresenter.present(m.formula)} end),
      caption: caption(marginals, person, counted?)
    }
  end

  @doc """
  The formula assigns to show under whichever preset id is currently selected
  (`selected_preset_id` — `nil`, or a stale/foreign id, falls back to Likely's own,
  `HC-10`'s "defaults to Likely"). `nil` when `:ranged` is `:missing` (no formula to
  show).
  """
  @spec selected_formula(t(), term() | nil) :: FormulaPresenter.assigns() | nil
  def selected_formula(%{ranged: :missing}, _selected_preset_id), do: nil

  def selected_formula(%{ranged: ranged, formulas: formulas}, selected_preset_id) do
    Map.fetch!(formulas, selected_role(ranged, selected_preset_id))
  end

  defp selected_role(%{minimum: minimum, maximum: maximum}, selected_preset_id) do
    cond do
      matches_preset?(minimum, selected_preset_id) -> :minimum
      matches_preset?(maximum, selected_preset_id) -> :maximum
      true -> :likely
    end
  end

  defp matches_preset?(_figure, nil), do: false

  defp matches_preset?(%{preset_id: id}, selected_preset_id),
    do: to_string(id) == to_string(selected_preset_id)

  # -- ranged (WeddingPlannerWeb.BudgetOverview's build_ranged/3 precedent) --------------

  defp build_ranged(%{minimum: minimum, likely: likely, maximum: maximum}) do
    entries = %{
      minimum: figure(:minimum, minimum),
      likely: figure(:likely, likely),
      maximum: figure(:maximum, maximum)
    }

    equal? =
      WeddingPlanner.Money.compare(money(minimum), money(likely)) == :eq and
        WeddingPlanner.Money.compare(money(likely), money(maximum)) == :eq

    Map.put(entries, :equal?, equal?)
  end

  defp figure(role, %{preset: preset} = marginal) do
    amount = money(marginal)

    %{
      role: role,
      value: Format.money(amount),
      preset_id: preset.id,
      preset_name: preset.name,
      money: amount
    }
  end

  defp money(%{formula: %{total: {:money, %Money{} = money}}}), do: money

  # The preset selector's own scope (flagged to the orchestrator): `Simulation.marginal_cost/2`
  # only ever evaluates the three **role** presets (`WeddingPlanner.Valuation.PresetChoice.role_presets/1`)
  # — there is no "marginal cost at an arbitrary preset" function — so, unlike `/budget`'s
  # own selector (every stored preset), this one can only meaningfully offer the same
  # three role presets `role_values/1` already shows, in role order.
  defp preset_options(%{minimum: minimum, likely: likely, maximum: maximum}) do
    Enum.map([minimum, likely, maximum], fn %{preset: preset} ->
      %{id: preset.id, name: preset.name}
    end)
  end

  # -- caption (DR-81) -------------------------------------------------------------------

  defp caption(_marginals, _person, false), do: @not_counted_caption

  defp caption(%{likely: %{removed: removed}}, person, true),
    do: removal_caption(removed, person)

  defp removal_caption(_removed, %Person{host_id: host_id} = person) when not is_nil(host_id) do
    _ = person
    "How much the forecast would drop without this +1"
  end

  defp removal_caption([_host | plus_ones], %Person{} = person) do
    "How much the forecast would drop without #{Person.display_name(person)}#{plus_one_clause(plus_ones)}"
  end

  defp plus_one_clause([]), do: ""
  defp plus_one_clause([_one]), do: " and their +1"
  defp plus_one_clause([_, _ | _]), do: " and their +1s"
end
