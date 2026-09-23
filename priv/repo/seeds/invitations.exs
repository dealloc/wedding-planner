defmodule WeddingPlanner.Seeds.Invitations do
  @moduledoc """
  Demo invitations (task 45; `docs/modules/guests-and-events.md` `INVT-01`–`INVT-04`,
  `PER-13`, `PER-14`) for the `/invitations` matrix: a deterministic status pattern —
  mostly *planned*/*invited*, a smaller share *accepted*/*declined* — across every
  seeded host × event pair, through `WeddingPlanner.Invitations.set_invitation_status/4`
  (never a direct `Repo.insert!`) so each write gets a real activity-log entry
  (`XC-10`), plus two deliberate exceptions for the demo:

    * every *want tier: maybe* host (`priv/repo/seeds/people.exs`'s Griet Peeters and
      Marie Segers) is left **not invited** to the Reception, so the `INVT-04` B-list
      filter ("want tier maybe, not invited to `<event>`") has something to show.
    * Jasper Van Damme is pinned *accepted* for the Party and his confirmed +1 (Kaat
      Willems) is opted out of that one event (`PER-13`) — the opt-out demo needs a
      host status that is not itself *not invited*/*declined* (`PER-14` would otherwise
      make the opt-out moot regardless of what it's set to), so this one cell is pinned
      rather than left to the deterministic pattern, mirroring the exact contrast
      `.claude/design/ui-decisions.md` §5 confirmed live: opted out at the pinned event,
      still following the host everywhere else.

  Idempotent: runs only while the `invitations` table is empty — see
  `priv/repo/seeds.exs`. Requires `priv/repo/seeds/people.exs` and
  `priv/repo/seeds/events.exs` to have already run (needs real persons/events to
  reference).
  """

  alias WeddingPlanner.Accounts.Scope
  alias WeddingPlanner.Events
  alias WeddingPlanner.Guests
  alias WeddingPlanner.Guests.Person
  alias WeddingPlanner.Invitations
  alias WeddingPlanner.Invitations.Invitation
  alias WeddingPlanner.Repo

  @reception_name "Reception"
  @party_name "Party"
  @pinned_host {"Jasper", "Van Damme"}
  @pinned_plus_one {"Kaat", "Willems"}

  @spec run(Scope.t()) :: :ok
  def run(%Scope{} = scope) do
    if Repo.aggregate(Invitation, :count) == 0 do
      events = Events.list_events()
      hosts = Guests.list_persons(%{}) |> Enum.reject(&Person.plus_one?/1)

      count =
        hosts
        |> Enum.with_index()
        |> Enum.flat_map(fn {host, host_index} -> seed_host(scope, host, host_index, events) end)
        |> length()

      pin_party_demo(scope, events)

      IO.puts("invitations: set #{count} statuses (plus the Party/+1 opt-out demo)")
    else
      IO.puts("skipping invitations — already has data")
    end

    :ok
  end

  defp seed_host(scope, host, host_index, events) do
    events
    |> Enum.with_index()
    |> Enum.reject(fn {event, _event_index} -> skip?(host, event) end)
    |> Enum.map(fn {event, event_index} ->
      status = pattern_status(host_index, event_index)
      {:ok, _invitation} = Invitations.set_invitation_status(scope, host, event, status)
      status
    end)
  end

  defp skip?(%Person{want_tier: :maybe}, %{name: @reception_name}), do: true
  defp skip?(_host, _event), do: false

  # Deterministic mix (no randomness, so the seed is repeatable): 4/10 planned, 4/10
  # invited, 1/10 accepted, 1/10 declined.
  defp pattern_status(host_index, event_index) do
    case rem(host_index * 7 + event_index * 3, 10) do
      n when n in [0, 1, 2, 3] -> :planned
      n when n in [4, 5, 6, 7] -> :invited
      8 -> :accepted
      9 -> :declined
    end
  end

  defp pin_party_demo(scope, events) do
    party = Enum.find(events, &(&1.name == @party_name))
    {host_first, host_last} = @pinned_host
    {plus_one_first, plus_one_last} = @pinned_plus_one

    persons = Guests.list_persons(%{})
    host = Enum.find(persons, &(&1.first_name == host_first and &1.last_name == host_last))

    plus_one =
      Enum.find(persons, &(&1.first_name == plus_one_first and &1.last_name == plus_one_last))

    if party && host && plus_one do
      {:ok, _invitation} = Invitations.set_invitation_status(scope, host, party, :accepted)
      {:ok, _opt_out} = Invitations.set_opt_out(scope, plus_one, party, true)
    else
      IO.puts(
        "invitations: skipped the Party/+1 opt-out demo — check people.exs/events.exs seed names"
      )
    end
  end
end
