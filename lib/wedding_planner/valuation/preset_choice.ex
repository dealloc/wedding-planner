defmodule WeddingPlanner.Valuation.PresetChoice do
  @moduledoc """
  The single place that decides **which stored preset a single-figure view starts on**
  and **which two stored presets bound a range** (`DR-54`).

  Once presets are user data (`DR-53`, task 58) and renameable (task 62), no view may
  find a preset by its hard-coded name — a rename would silently break it. Identity is
  the stored `role` (`WeddingPlanner.Valuation.Preset.t/0`'s `:role` field: `nil` |
  `:minimum` | `:likely` | `:maximum`, at most one preset per role), never the name.
  This module supersedes `DR-51`'s lookup by the three fixed names.

  Pure over a plain list of `WeddingPlanner.Valuation.Preset` (typically
  `snapshot.headcount_presets`, already sorted in display order by
  `WeddingPlanner.Valuation.Snapshot.Loader`) — no database access, no LiveView
  concerns. Money is only ever compared here (`Money.compare/2`), never built or added
  (`DR-18`).
  """

  alias WeddingPlanner.Valuation.Preset

  @doc """
  The default single-figure preset (`HC-10`: "defaults to Likely"): the preset with
  role `:likely`, else the first preset in `presets`' own order, else `nil` when
  `presets` is empty.
  """
  @spec default([Preset.t()]) :: Preset.t() | nil
  def default(presets) when is_list(presets) do
    Enum.find(presets, &(&1.role == :likely)) || List.first(presets)
  end

  @doc """
  The preset in `presets` whose id matches `id_or_string` (compared as strings, so the
  radio's submitted string form matches a preset whose id is an integer), or
  `default/1` when `id_or_string` is `nil` or names no preset in `presets` (e.g. it was
  deleted since the view last rendered).
  """
  @spec find([Preset.t()], term() | nil) :: Preset.t() | nil
  def find(presets, id_or_string) when is_list(presets) do
    Enum.find(presets, &matching_id?(&1, id_or_string)) || default(presets)
  end

  defp matching_id?(_preset, nil), do: false
  defp matching_id?(%Preset{id: id}, id_or_string), do: to_string(id) == to_string(id_or_string)

  @doc """
  The two presets that bound the range (`CST-53`): the preset with role `:minimum` and
  the preset with role `:maximum`, as `{minimum_role_preset, maximum_role_preset}`.
  `:missing` when either role is unassigned.
  """
  @spec range_presets([Preset.t()]) :: {:ok, {Preset.t(), Preset.t()}} | :missing
  def range_presets(presets) when is_list(presets) do
    minimum = Enum.find(presets, &(&1.role == :minimum))
    maximum = Enum.find(presets, &(&1.role == :maximum))

    if minimum && maximum do
      {:ok, {minimum, maximum}}
    else
      :missing
    end
  end

  @doc """
  Applies `figure_fun` to the two role presets from `range_presets/1` and orders the
  two results low then high with `Money.compare/2` — a read-only comparison, never
  arithmetic — so an inverted edit (the minimum-role preset computing the larger
  figure) still reads low–high. `:missing` when either role is unassigned.
  """
  @spec range([Preset.t()], (Preset.t() -> Money.t())) :: {:ok, {Money.t(), Money.t()}} | :missing
  def range(presets, figure_fun) when is_list(presets) and is_function(figure_fun, 1) do
    case range_presets(presets) do
      :missing ->
        :missing

      {:ok, {minimum_role_preset, maximum_role_preset}} ->
        minimum_role_value = figure_fun.(minimum_role_preset)
        maximum_role_value = figure_fun.(maximum_role_preset)

        case Money.compare(minimum_role_value, maximum_role_value) do
          :gt -> {:ok, {maximum_role_value, minimum_role_value}}
          _ -> {:ok, {minimum_role_value, maximum_role_value}}
        end
    end
  end
end
