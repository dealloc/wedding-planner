defmodule WeddingPlannerWeb.Export do
  @moduledoc """
  The export **kind** registry `WeddingPlannerWeb.ExportController` looks up `:kind`
  params against (`XC-30`, `DR-87`).

  Kinds are plain **strings** — never an atom built from a request param, and never
  written anywhere in `lib/` as the bare atom `WeddingPlanner.Valuation.EnginesTest`'s
  source scan forbids (that engine's own test seam, unrelated to this registry; the
  headcount-per-event export's kind is only ever the plain string `"headcount"`, added
  by task 93/94). This task registers the four "plain" exports; task 94 (`DR-87`) appends
  the three computed kinds below.
  """

  alias WeddingPlannerWeb.Export.Budget
  alias WeddingPlannerWeb.Export.Events
  alias WeddingPlannerWeb.Export.Headcount
  alias WeddingPlannerWeb.Export.Invoices
  alias WeddingPlannerWeb.Export.Offers
  alias WeddingPlannerWeb.Export.Persons
  alias WeddingPlannerWeb.Export.Tasks

  @exporters %{
    "persons" => Persons,
    "events" => Events,
    "invoices" => Invoices,
    "tasks" => Tasks,
    "headcount" => Headcount,
    "offers" => Offers,
    "budget" => Budget
  }

  @doc "Every registered export kind (a string) to its `WeddingPlannerWeb.Export.Exporter` module."
  @spec exporters() :: %{String.t() => module()}
  def exporters, do: @exporters
end
