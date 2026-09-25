defmodule WeddingPlannerWeb.Export.Budget do
  @moduledoc """
  The budget CSV export (`XC-30` "budget per category and layer", `XC-32`, `DR-89`):
  one row per category with its `BUD-02` layers, then a `"Total"` row (`BUD-05`), read
  from `WeddingPlanner.Valuation.Budget.for_roles/2` (`BUD-04`, `DR-78`).

  ## Rows

    * One row per category in `snapshot.categories` order (`CST-01`), empty categories
      included (`BUD-03`: they forecast zero rather than being excluded).
    * Then `"Total"`, from each role preset's `overall` result (`DR-72`).

  ## Columns

  `Category, Forecast basis, Target, Committed — <minimum>, Committed — <likely>,
  Committed — <maximum>, Invoiced, Paid, Outstanding, Forecast — <minimum>,
  Forecast — <likely>, Forecast — <maximum>, Needs attention, Currency`

    * `<minimum>`/`<likely>`/`<maximum>` are the stored names of the three **role**
      presets (`WeddingPlanner.Valuation.PresetChoice.role_presets/1`, `DR-54`), always in
      that order: Committed and Forecast depend on the guest list, so they are given per
      preset and every such header names its preset (`BUD-04`, `HC-08`).
    * Forecast basis is `BUD-03`'s branch: `Confirmed offers`, `Planning pick`,
      `Target` or `No target` (blank on the Total row). It does not depend on the
      preset; it is read from the likely role.
    * Target is blank when unset (`BUD-03` counts it as zero); the Total row's Target is
      the sum of the targets that are set (`DR-72`).
    * Invoiced, Paid and Outstanding do not depend on the preset (read from the likely
      role).
    * Needs attention is `true` when the category's `needs_attention` list is non-empty
      — a confirmed offer (or the planning pick the forecast rests on) has an invalid
      line (`XC-42`, `D-26`, `DR-84`); blank on the Total row.
    * Currency is last: the row's currency code.

  Overall budget, Available and Spent are overall figures, not category layers, and are
  not in this file.

  ## Rounding (`NFR-14`)

  Every money cell is the budget engine's **unrounded** `%Money{}`; the encoder rounds
  each cell once, on output. The Total row is the engine's own total of the unrounded
  layers, never a sum of rounded rows, so the displayed category rows may differ from
  the displayed Total by a cent — `NFR-14`'s expected discrepancy.

  ## No role preset (defensive, `DR-54`)

  When `for_roles/2` is `:missing` (a role unassigned — impossible since the three
  defaults are locked), the preset-independent columns are read from
  `WeddingPlanner.Valuation.Budget.overall/3` under `PresetChoice.default/1`, the six
  preset columns are blank and headed by the role words `Minimum`/`Likely`/`Maximum`.
  Never raises.

  Nothing is computed here: every figure is the budget engine's (`DR-89`). `load/0` is
  the only database read; `table/2` is pure and ignores `today`.
  """

  @behaviour WeddingPlannerWeb.Export.Exporter

  alias WeddingPlanner.Repo
  alias WeddingPlanner.Valuation.Budget, as: BudgetEngine
  alias WeddingPlanner.Valuation.Formula
  alias WeddingPlanner.Valuation.Preset
  alias WeddingPlanner.Valuation.PresetChoice
  alias WeddingPlanner.Valuation.Snapshot

  @roles [:minimum, :likely, :maximum]
  @role_words %{minimum: "Minimum", likely: "Likely", maximum: "Maximum"}

  @doc "The live planning state (`XC-32`) — the export's only database read."
  @impl true
  @spec load() :: Snapshot.t()
  def load, do: Snapshot.load(Repo)

  @doc """
  The budget table of `snapshot` (see the moduledoc). Pure; `today` is accepted for the
  exporter contract and ignored.
  """
  @impl true
  @spec table(Snapshot.t(), Date.t()) :: WeddingPlannerWeb.Export.Table.t()
  def table(%Snapshot{} = snapshot, _today) do
    {names, plain, by_role} =
      case BudgetEngine.for_roles(snapshot) do
        {:ok, overalls} ->
          by_role = Enum.map(@roles, &Map.fetch!(overalls, &1))
          {Enum.map(by_role, & &1.preset.name), overalls.likely, by_role}

        :missing ->
          plain = BudgetEngine.overall(snapshot, plain_preset(snapshot))
          {Enum.map(@roles, &Map.fetch!(@role_words, &1)), plain, [nil, nil, nil]}
      end

    rows =
      Enum.map(snapshot.categories, &category_row(&1, plain, by_role)) ++
        [total_row(plain, by_role)]

    %{stem: "budget", headers: headers(names), rows: rows}
  end

  defp headers(names) do
    ["Category", "Forecast basis", "Target"] ++
      Enum.map(names, &"Committed — #{&1}") ++
      ["Invoiced", "Paid", "Outstanding"] ++
      Enum.map(names, &"Forecast — #{&1}") ++
      ["Needs attention", "Currency"]
  end

  # For preset-independent layers only; never shown. `PresetChoice.default/1` is `nil` only
  # when no preset is stored at all, which the three locked defaults make impossible — the
  # placeholder merely keeps `table/2` total.
  defp plain_preset(%Snapshot{headcount_presets: presets}) do
    PresetChoice.default(presets) || %Preset{name: "No preset"}
  end

  defp category_row(category, plain, by_role) do
    layers = layers_of(plain, category)
    per_role = Enum.map(by_role, &(&1 && layers_of(&1, category)))

    with_currency(
      [category.name, branch_word(layers.branch), layers.target] ++
        Enum.map(per_role, &formula_money(&1, :committed)) ++
        [layers.invoiced, layers.paid, layers.outstanding] ++
        Enum.map(per_role, &formula_money(&1, :forecast)) ++
        [layers.needs_attention != []]
    )
  end

  defp total_row(plain, by_role) do
    with_currency(
      ["Total", nil, plain.target] ++
        Enum.map(by_role, &formula_money(&1, :committed)) ++
        [plain.invoiced, plain.paid, plain.outstanding] ++
        Enum.map(by_role, &formula_money(&1, :forecast)) ++
        [nil]
    )
  end

  defp layers_of(overall, category),
    do: Enum.find(overall.categories, &(&1.category.id == category.id))

  defp formula_money(nil, _layer), do: nil

  defp formula_money(figures, layer) do
    %Formula{total: {:money, %Money{} = money}} = Map.fetch!(figures, layer)
    money
  end

  defp branch_word(:confirmed), do: "Confirmed offers"
  defp branch_word(:planning_pick), do: "Planning pick"
  defp branch_word(:target), do: "Target"
  defp branch_word(:no_target), do: "No target"

  defp with_currency(cells), do: cells ++ [currency(cells)]

  defp currency(cells) do
    Enum.find_value(cells, fn
      %Money{currency: currency} -> Atom.to_string(currency)
      _other -> nil
    end)
  end
end
