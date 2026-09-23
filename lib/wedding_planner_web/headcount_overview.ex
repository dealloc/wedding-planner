defmodule WeddingPlannerWeb.HeadcountOverview do
  @moduledoc """
  The pure view-model builder behind `/headcount` (`docs/modules/headcount.md` `HC-03`,
  `HC-08`, `HC-09`; `DR-55`). Turns a `WeddingPlanner.Valuation.Snapshot` plus an
  optional ad hoc `WeddingPlanner.Valuation.Preset` into the rows/columns/cells
  `WeddingPlannerWeb.Live.HeadcountLive` renders — no database, no LiveView concerns
  (`NFR-41`), so it is unit-testable over in-memory snapshots the same way every other
  `WeddingPlanner.Valuation` engine is.

  ## Shape

  Columns are `snapshot.headcount_presets` (already in `sort_order` — `HC-06`'s display
  order) plus, when `adhoc_preset` is given, one more column for it (`HC-07`). Rows are
  `snapshot.events` (`EVT-04` manual sort order, already how the snapshot carries them)
  plus a trailing "All events" row (`HC-03`: distinct persons counted for at least one
  event). Every row's `:cells` map is keyed by the same column id used in `:columns`, so
  the caller looks a cell up as `row.cells[column.id]`.

  Each cell carries:

    * `:total_text` — `"\#{adults} + \#{children} = \#{total}"` in plain digits (the
      caller renders it in tabular mono), computed via
      `WeddingPlanner.Valuation.Headcount.evaluate/3` — never re-derived by summing
      anything else (`DR-55`'s "the three can never disagree").
    * `:formula` — `WeddingPlannerWeb.FormulaPresenter.present/1` of
      `WeddingPlanner.Valuation.Headcount.explain/3`'s result, ready for
      `WeddingPlannerWeb.DisplayComponents.formula/1`.
    * `:names` — display names of everyone `WeddingPlanner.Valuation.Headcount.counted/3`
      counts, adults first then children (each group in `snapshot.persons` order), an
      unnamed +1 rendered as `"+1 of <host>"` (`PER-11`) — the host is looked up in
      `snapshot.persons` here, since snapshot persons carry no preloaded `:host`
      association (`WeddingPlanner.Valuation.Snapshot`'s "resolve by id" convention).

  A column's id is `to_string(preset.id)` for a stored preset, or `"adhoc"` for the ad
  hoc column (which always has `id: nil`, `HC-07`). A row's id is `to_string(event.id)`
  for an event, or `"all"` for the "All events" row.
  """

  alias WeddingPlanner.Events.Event
  alias WeddingPlanner.Guests.Person
  alias WeddingPlanner.Valuation.Headcount
  alias WeddingPlanner.Valuation.Preset
  alias WeddingPlanner.Valuation.Snapshot
  alias WeddingPlannerWeb.FormulaPresenter

  @typedoc "One cell: the plain total text, the formula assigns and the counted names."
  @type cell :: %{
          total_text: String.t(),
          formula: FormulaPresenter.assigns(),
          names: [String.t()]
        }

  @typedoc "One column header: its dom-safe id and display label (the preset's name)."
  @type column :: %{id: String.t(), label: String.t()}

  @typedoc "One row: its dom-safe id, display label, target and cells keyed by column id."
  @type row :: %{
          id: String.t(),
          label: String.t(),
          target: Event.t() | :all_events,
          cells: %{String.t() => cell()}
        }

  @doc """
  Builds the overview's rows and columns for `snapshot`, optionally with one more
  ad hoc column for `adhoc_preset` (`nil` when no ad hoc filter is active, `HC-07`).
  """
  @spec build(Snapshot.t(), Preset.t() | nil) :: %{rows: [row()], columns: [column()]}
  def build(%Snapshot{} = snapshot, adhoc_preset) do
    presets = snapshot.headcount_presets ++ List.wrap(adhoc_preset)
    persons_by_id = Map.new(snapshot.persons, &{&1.id, &1})

    columns = Enum.map(presets, &column_for/1)

    rows =
      Enum.map(snapshot.events, &build_row(snapshot, persons_by_id, presets, &1)) ++
        [build_row(snapshot, persons_by_id, presets, :all_events)]

    %{rows: rows, columns: columns}
  end

  # -- columns -----------------------------------------------------------------------------

  defp column_for(%Preset{id: nil, name: name}), do: %{id: "adhoc", label: name}
  defp column_for(%Preset{id: id, name: name}), do: %{id: to_string(id), label: name}

  defp col_id(%Preset{id: nil}), do: "adhoc"
  defp col_id(%Preset{id: id}), do: to_string(id)

  # -- rows --------------------------------------------------------------------------------

  defp build_row(snapshot, persons_by_id, presets, :all_events) do
    %{
      id: "all",
      label: "All events",
      target: :all_events,
      cells: build_cells(snapshot, persons_by_id, presets, :all_events)
    }
  end

  defp build_row(snapshot, persons_by_id, presets, %Event{} = event) do
    %{
      id: to_string(event.id),
      label: event.name,
      target: event,
      cells: build_cells(snapshot, persons_by_id, presets, event)
    }
  end

  defp build_cells(snapshot, persons_by_id, presets, target) do
    Map.new(presets, fn preset ->
      {col_id(preset), build_cell(snapshot, persons_by_id, preset, target)}
    end)
  end

  defp build_cell(snapshot, persons_by_id, preset, target) do
    counts = Headcount.evaluate(snapshot, preset, target)
    formula = snapshot |> Headcount.explain(preset, target) |> FormulaPresenter.present()
    names = names_for(snapshot, persons_by_id, preset, target)

    %{
      total_text: "#{counts.adults} + #{counts.children} = #{counts.total}",
      formula: formula,
      names: names
    }
  end

  # -- who is counted (adults, then children; +1s resolved against the snapshot) -----------

  defp names_for(snapshot, persons_by_id, preset, :all_events) do
    snapshot
    |> Headcount.counted(preset, :all_events)
    |> Enum.map(& &1.person)
    |> sorted_display_names(persons_by_id)
  end

  defp names_for(snapshot, persons_by_id, preset, %Event{} = event) do
    snapshot
    |> Headcount.counted(preset, event)
    |> Enum.map(& &1.person)
    |> sorted_display_names(persons_by_id)
  end

  defp sorted_display_names(persons, persons_by_id) do
    {adults, children} = Enum.split_with(persons, &(&1.age_category == :adult))
    Enum.map(adults ++ children, &display_name(&1, persons_by_id))
  end

  defp display_name(%Person{host_id: nil} = person, _persons_by_id),
    do: Person.display_name(person)

  defp display_name(%Person{host_id: host_id} = person, persons_by_id) do
    host = Map.fetch!(persons_by_id, host_id)
    Person.display_name(%{person | host: host})
  end
end
