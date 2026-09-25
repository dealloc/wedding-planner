defmodule WeddingPlannerWeb.Export.Headcount do
  @moduledoc """
  The headcount CSV export (`XC-30` "headcount (per event × preset)", `XC-32`, `DR-89`):
  one row per (event, preset), in long format, so a spreadsheet can filter or pivot it.

  ## Rows

    * Events in `snapshot.events` order (`EVT-04`), then one group labelled
      `"All events"` — `HC-03`'s distinct persons counted for at least one event, split
      by each person's own age category (`DR-48`), never a sum of the event rows.
    * Within each group, **every** stored preset in `snapshot.headcount_presets` order
      (`HC-06`'s display order) — custom presets included, not only the three role
      presets (`HC-09`: every preset side by side).
    * No events → only the `"All events"` rows. No presets → a header-only table.

  ## Columns

  `Event, Preset, Adults, Children, Total` — the event name (or `"All events"`), the
  preset's stored `name` (`HC-08`: the preset used is visible on every count), then the
  integers of `WeddingPlanner.Valuation.Headcount.evaluate/3` for that event (or
  `:all_events`) and preset. There is no money, so there is no `Currency` column.

  Every count is read from the headcount engine; nothing is counted here (`DR-89`).

  `load/0` is the only database read (`WeddingPlanner.Valuation.Snapshot.load/1`);
  `table/2` is pure and ignores `today` — a headcount does not depend on the date.
  """

  alias WeddingPlanner.Repo
  alias WeddingPlanner.Valuation.Headcount, as: HeadcountEngine
  alias WeddingPlanner.Valuation.Snapshot

  @headers ["Event", "Preset", "Adults", "Children", "Total"]

  @all_events_label "All events"

  @doc "The live planning state (`XC-32`) — the export's only database read."
  @spec load() :: Snapshot.t()
  def load, do: Snapshot.load(Repo)

  @doc """
  The headcount table of `snapshot` (see the moduledoc). Pure; `today` is accepted for
  the exporter contract and ignored.
  """
  @spec table(Snapshot.t(), Date.t()) :: WeddingPlannerWeb.Export.Table.t()
  def table(%Snapshot{} = snapshot, _today) do
    targets =
      Enum.map(snapshot.events, &{&1.name, &1}) ++ [{@all_events_label, :all_events}]

    rows =
      for {label, target} <- targets, preset <- snapshot.headcount_presets do
        %{adults: adults, children: children, total: total} =
          HeadcountEngine.evaluate(snapshot, preset, target)

        [label, preset.name, adults, children, total]
      end

    %{stem: "headcount", headers: @headers, rows: rows}
  end
end
