defmodule WeddingPlanner.Guests.PlusOne do
  @moduledoc """
  Pure PER-15 helper: what a +1 inherits from its host.

  `docs/modules/guests-and-events.md` `PER-15`: "A +1 has its own age category. Want tier
  and certainty are inherited from the host and not editable on the +1, with one
  status does not change that (see HC-05)."

  `WeddingPlanner.Guests.Person`'s own `want_tier`/`certainty` columns on a +1 row are
  written once at creation and then **never read** (`DR-32`) — every reader, this
  context's own filters/sorts, the people screens, G4's headcount engine and X1's export,
  goes through the functions here instead, so there is exactly one place that knows how a
  +1's effective want tier, certainty and group are computed.

  For a non-+1, every function here is the identity: it simply returns the person's own
  field. `group_id/2` implements `DR-32`'s "a +1 has no group of its own" — it is shown,
  filtered and evaluated under its **host's** group ("a +1 follows its host", `D-02`).

  This module is **PER-15 only**. `G4` layers `HC-04` ("accepted ⇒ certain") on top of
  `certainty/2`'s result — that layering happens in the headcount engine, not here.

  No database access of any kind: every function is a pure computation over bare structs,
  so it can be unit-tested (and doctested) without touching storage.
  """

  alias WeddingPlanner.Guests.Person

  @doc """
  `person`'s effective want tier: `host`'s want tier for a +1, `person`'s own otherwise
  (`PER-15`).

      iex> host = %WeddingPlanner.Guests.Person{want_tier: :maybe}
      iex> plus_one = %WeddingPlanner.Guests.Person{host_id: 1, want_tier: :yes}
      iex> WeddingPlanner.Guests.PlusOne.want_tier(plus_one, host)
      :maybe

      iex> host = %WeddingPlanner.Guests.Person{want_tier: :maybe}
      iex> WeddingPlanner.Guests.PlusOne.want_tier(host, host)
      :maybe
  """
  @spec want_tier(Person.t(), Person.t()) :: Person.want_tier()
  def want_tier(%Person{host_id: nil} = person, _host), do: person.want_tier
  def want_tier(%Person{}, %Person{} = host), do: host.want_tier

  @doc """
  `person`'s effective certainty (`PER-15`, `HC-05`): `host`'s certainty for a +1,
  whatever its `plus_one_status`; `person`'s own certainty for a non-+1.

      iex> host = %WeddingPlanner.Guests.Person{certainty: :certain}
      iex> confirmed = %WeddingPlanner.Guests.Person{host_id: 1, plus_one_status: :confirmed}
      iex> WeddingPlanner.Guests.PlusOne.certainty(confirmed, host)
      :certain

      iex> host = %WeddingPlanner.Guests.Person{certainty: :certain}
      iex> possible = %WeddingPlanner.Guests.Person{host_id: 1, plus_one_status: :possible}
      iex> WeddingPlanner.Guests.PlusOne.certainty(possible, host)
      :certain
  """
  @spec certainty(Person.t(), Person.t()) :: Person.certainty()
  def certainty(%Person{host_id: nil} = person, _host), do: person.certainty
  def certainty(%Person{}, %Person{} = host), do: host.certainty

  @doc """
  `person`'s effective group id (`DR-32`: a +1 has no group of its own): `host`'s
  `group_id` for a +1, `person`'s own otherwise.

      iex> host = %WeddingPlanner.Guests.Person{group_id: 7}
      iex> plus_one = %WeddingPlanner.Guests.Person{host_id: 1, group_id: nil}
      iex> WeddingPlanner.Guests.PlusOne.group_id(plus_one, host)
      7
  """
  @spec group_id(Person.t(), Person.t()) :: term() | nil
  def group_id(%Person{host_id: nil} = person, _host), do: person.group_id
  def group_id(%Person{}, %Person{} = host), do: host.group_id

  @doc """
  `want_tier/2` for a `person` whose `:host` association is already preloaded (a non-+1
  needs no preload). Raises `ArgumentError` for a +1 whose `:host` is not loaded.
  """
  @spec want_tier(Person.t()) :: Person.want_tier()
  def want_tier(%Person{host_id: nil} = person), do: person.want_tier
  def want_tier(%Person{} = person), do: want_tier(person, loaded_host!(person))

  @doc "`certainty/2` for a `person` with `:host` preloaded. See `want_tier/1`."
  @spec certainty(Person.t()) :: Person.certainty()
  def certainty(%Person{host_id: nil} = person), do: person.certainty
  def certainty(%Person{} = person), do: certainty(person, loaded_host!(person))

  @doc "`group_id/2` for a `person` with `:host` preloaded. See `want_tier/1`."
  @spec group_id(Person.t()) :: term() | nil
  def group_id(%Person{host_id: nil} = person), do: person.group_id
  def group_id(%Person{} = person), do: group_id(person, loaded_host!(person))

  defp loaded_host!(%Person{host: %Person{} = host}), do: host

  defp loaded_host!(%Person{id: id}) do
    raise ArgumentError,
          "WeddingPlanner.Guests.PlusOne needs :host preloaded for +1 person id=#{inspect(id)}; " <>
            "preload :host first, or use the /2 functions with the host passed explicitly"
  end
end
