defmodule WeddingPlannerWeb.Export.Exporter do
  @moduledoc """
  The behaviour every CSV export module implements (`XC-30`, `DR-87`, `DR-88`; contract
  shared verbatim with task 93, `.claude/plans/w14-plan.md` §5).

  `load/0` is the **only** database read (typically `WeddingPlanner.Valuation.Snapshot.load/1`,
  or, for tasks, `WeddingPlanner.Tasks.list_tasks_with_graph/0`); `table/2` is a pure
  function of that data plus `today` (the requesting viewer's date, `DR-87`) into a
  `WeddingPlannerWeb.Export.Table.t()` — no `Repo`, no `Phoenix`, so it can be
  example-tested without a database (`NFR-41`).

  `WeddingPlannerWeb.Export.exporters/0` maps an export **kind** (a string — never an
  atom built from a param; see that module's moduledoc for the source-scan rule this
  keeps to) to the implementing module.
  """

  alias WeddingPlannerWeb.Export.Table

  @doc "The one database read this exporter needs. Whatever it returns is passed to `table/2` unchanged."
  @callback load() :: term()

  @doc "Pure: turns `load/0`'s result plus `today` into a `WeddingPlannerWeb.Export.Table.t()`."
  @callback table(data :: term(), today :: Date.t()) :: Table.t()
end
