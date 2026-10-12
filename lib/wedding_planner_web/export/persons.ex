defmodule WeddingPlannerWeb.Export.Persons do
  @moduledoc """
  The persons export (`XC-30`, `D-29`, `PER-11`, `PER-13`, `PER-14`, `PER-15`, `DR-88`):
  one row per person, in `WeddingPlanner.Guests.list_persons/1`'s default order (host
  units, `DR-34` — a host immediately followed by its own +1s).

  Columns: `First name, Last name, Display name, Group, Group type, Host, +1 status, Age
  category, Want tier, Certainty, <one column per event in EVT-04 order, headed by its
  name>, Notes`.

    * First/last name are separate columns (`D-29`) — a non-+1 always has at least one
      (`PER-02`); an unnamed +1 has both blank and `Display name` "+1 of &lt;host&gt;"
      (`PER-11`).
    * Group / Group type are the +1's **host's** (`WeddingPlanner.Guests.PlusOne.group_id/2`,
      `DR-32`/`DR-34`), resolved against `snapshot.groups`; blank when ungrouped.
    * Want tier / Certainty are `WeddingPlanner.Guests.PlusOne`'s *inherited* values
      (`PER-15`) — never a +1's own stored
      columns, which are written once at creation and never read again (`DR-32`).
    * Host is the host's display name for a +1, blank otherwise; `+1 status` is
      `possible`/`confirmed` for a +1, blank otherwise.
    * Each event column is the person's **effective** invitation status
      (`WeddingPlanner.Invitations.Effective.status/3`, `PER-13`/`PER-14`), labelled with
      `WeddingPlannerWeb.WhatIfView.status_label/1`.

  Enum columns render the same words `/people` shows (`age_label`/`want_label`/
  `certainty_label`/`plus_one_status_label`'s idiom there — private in that LiveView, so
  reproduced here rather than shared).

  No money is exported here, so there is no `Currency` column (the contract's rule only
  applies to a table that has one).
  """

  @behaviour WeddingPlannerWeb.Export.Exporter

  alias WeddingPlanner.Guests
  alias WeddingPlanner.Guests.Person
  alias WeddingPlanner.Guests.PlusOne
  alias WeddingPlanner.Invitations.Effective
  alias WeddingPlanner.Repo
  alias WeddingPlanner.Valuation.Snapshot
  alias WeddingPlannerWeb.Export.Table
  alias WeddingPlannerWeb.WhatIfView

  @impl true
  @spec load() :: %{persons: [Person.t()], snapshot: Snapshot.t()}
  def load do
    %{persons: Guests.list_persons(), snapshot: Snapshot.load(Repo)}
  end

  @impl true
  @spec table(%{persons: [Person.t()], snapshot: Snapshot.t()}, Date.t()) :: Table.t()
  def table(%{persons: persons, snapshot: snapshot}, %Date{}) do
    events = snapshot.events
    lookup = Effective.index(snapshot.persons, snapshot.invitations, snapshot.plus_one_opt_outs)
    groups_by_id = Map.new(snapshot.groups, &{&1.id, &1})

    headers =
      [
        "First name",
        "Last name",
        "Display name",
        "Group",
        "Group type",
        "Host",
        "+1 status",
        "Age category",
        "Want tier",
        "Certainty"
      ] ++ Enum.map(events, & &1.name) ++ ["Notes"]

    {rows, _last_host} =
      Enum.map_reduce(persons, nil, fn person, current_host ->
        host = if Person.plus_one?(person), do: current_host, else: person
        {row(person, host, events, lookup, groups_by_id), host}
      end)

    %{stem: "persons", headers: headers, rows: rows}
  end

  defp row(%Person{} = person, %Person{} = host, events, lookup, groups_by_id) do
    plus_one? = Person.plus_one?(person)
    group = person |> PlusOne.group_id(host) |> group_of(groups_by_id)

    [
      person.first_name,
      person.last_name,
      display_name(person, host, plus_one?),
      group_field(group, & &1.name),
      group_field(group, & &1.type_label),
      if(plus_one?, do: Person.display_name(host)),
      if(plus_one?, do: plus_one_status_label(person.plus_one_status)),
      age_category_label(person.age_category),
      want_tier_label(PlusOne.want_tier(person, host)),
      certainty_label(PlusOne.certainty(person, host))
    ] ++
      Enum.map(events, &event_cell(lookup, person, &1)) ++
      [person.notes]
  end

  defp event_cell(lookup, person, event) do
    lookup |> Effective.status(person, event.id) |> WhatIfView.status_label()
  end

  defp display_name(person, host, true), do: Person.display_name(%{person | host: host})
  defp display_name(person, _host, false), do: Person.display_name(person)

  defp group_of(nil, _groups_by_id), do: nil
  defp group_of(group_id, groups_by_id), do: Map.get(groups_by_id, group_id)

  defp group_field(nil, _fun), do: nil
  defp group_field(group, fun), do: fun.(group)

  defp age_category_label(:adult), do: "Adult"
  defp age_category_label(:child), do: "Child"

  defp want_tier_label(:yes), do: "Yes"
  defp want_tier_label(:maybe), do: "Maybe"
  defp want_tier_label(:no), do: "No"
  defp want_tier_label(:obligated), do: "Obligated"

  defp certainty_label(:certain), do: "Certain"
  defp certainty_label(:likely), do: "Likely"
  defp certainty_label(:uncertain), do: "Uncertain"

  defp plus_one_status_label(:possible), do: "Possible"
  defp plus_one_status_label(:confirmed), do: "Confirmed"
end
