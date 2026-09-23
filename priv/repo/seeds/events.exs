defmodule WeddingPlanner.Seeds.Events do
  @moduledoc """
  `DR-26` Q4 demo events: five events spanning the wedding day. Reception is
  deliberately left without a date (`EVT-03`) so the `TSK-03`/T4 relative-deadline
  resolution can be demoed by giving it one later. Idempotent: runs only while the
  `events` table is empty — see `priv/repo/seeds.exs`.
  """

  alias WeddingPlanner.Accounts.Scope
  alias WeddingPlanner.Events
  alias WeddingPlanner.Events.Event
  alias WeddingPlanner.Repo

  @spec run(Scope.t()) :: :ok
  def run(%Scope{} = scope) do
    if Repo.aggregate(Event, :count) == 0 do
      attrs_list = events()
      Enum.each(attrs_list, fn attrs -> {:ok, _event} = Events.create_event(scope, attrs) end)
      IO.puts("events: created #{length(attrs_list)} events")
    else
      IO.puts("skipping events — already has data")
    end

    :ok
  end

  defp events do
    wedding_day = Date.add(Date.utc_today(), 270)

    [
      %{name: "Civil ceremony", date: wedding_day, location: "Town hall"},
      %{name: "Church ceremony", date: wedding_day, location: "Sint-Pieterskerk"},
      %{name: "Reception", date: nil, location: "De Waterhoeve"},
      %{name: "Dinner", date: wedding_day, location: "De Waterhoeve"},
      %{name: "Party", date: wedding_day, location: "De Waterhoeve"}
    ]
  end
end
