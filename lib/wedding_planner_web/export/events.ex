defmodule WeddingPlannerWeb.Export.Events do
  @moduledoc """
  The events export (`XC-30`, `DR-88`): every event, in `EVT-04` order (the order stored
  on `WeddingPlanner.Valuation.Snapshot`'s `:events` collection), one row each.

  Columns: `Position, Name, Date, Location, Notes` — `Position` is 1-based; `Date` is a
  `%Date{}` (rendered `dd/mm/yyyy`, `NFR-23`) or blank when the event has no date yet
  (`EVT-03`). No money is exported here, so there is no `Currency` column.
  """

  @behaviour WeddingPlannerWeb.Export.Exporter

  alias WeddingPlanner.Repo
  alias WeddingPlanner.Valuation.Snapshot
  alias WeddingPlannerWeb.Export.Table

  @impl true
  @spec load() :: Snapshot.t()
  def load, do: Snapshot.load(Repo)

  @impl true
  @spec table(Snapshot.t(), Date.t()) :: Table.t()
  def table(%Snapshot{events: events}, %Date{}) do
    rows =
      events
      |> Enum.with_index(1)
      |> Enum.map(fn {event, position} ->
        [position, event.name, event.date, event.location, event.notes, event.couple_attends]
      end)

    %{
      stem: "events",
      headers: ["Position", "Name", "Date", "Location", "Notes", "Couple attends"],
      rows: rows
    }
  end
end
