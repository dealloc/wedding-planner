defmodule WeddingPlanner.Invitations.Matrix do
  @moduledoc """
  Pure row builder for the `/invitations` matrix (`INVT-02`, task 45, `DR-37`, `DR-39`,
  `.claude/design/ui-decisions.md` §5). No Ecto, no `Repo` — a function of data already
  in hand, tested exhaustively without touching storage.

  ## Host units (`DR-34`)

  `WeddingPlanner.Guests.list_persons/1` already returns persons in host-unit order:
  every +1 immediately follows its own host. `host_units/1` turns that flat, already-
  ordered list back into `{host, plus_ones}` pairs by walking it once and appending each
  +1 onto whichever host unit is currently being built — **not** `Enum.group_by/2`,
  which groups by key but does not promise to preserve cross-key ordering the way a
  literal walk does, and was the root cause of the invites-v4 prototype bug this design
  record calls out (a +1 rendered at the bottom of its group instead of directly under
  its host). If a +1 ever turns up before any host (a data invariant this app already
  guarantees — `PER-16` deletes a host's +1s with it), this raises loudly rather than
  silently misplacing the row.

  ## Filtering (`DR-34`, `DR-39`, `INVT-04`)

  A unit is shown if **any** of its members (the host or one of its +1s) individually
  satisfies **every** active filter at once — the same two-level rule
  `WeddingPlanner.Guests.list_persons/1` uses for the flat/grouped person list, so a
  +1's own want tier and effective status can bring its host unit into view even when
  the host itself would not match alone. A +1's want tier is read through
  `WeddingPlanner.Guests.PlusOne.want_tier/2` (`PER-15`) — its own column is never
  read directly.

  Three independent filter categories, AND-combined:

    * `:text` — case-insensitive substring match on `WeddingPlanner.Guests.Person.display_name/1`.
    * `:want_tier` — exact match on the effective want tier.
    * `:event_id` + `:status` together — the `INVT-04` B-list filter ("want tier maybe,
      not invited to `<event>`" is simply `:want_tier: :maybe` plus this pair with
      `:status: :not_invited`): the person's *effective* status for that one event
      (`WeddingPlanner.Invitations.Effective.status/3`) must equal `:status`. Inactive
      unless **both** `:event_id` and `:status` are set — a lone status pick with no
      event chosen filters nothing.

  ## Grouping (`DR-39`)

  `:flat` — one `{:unit, ...}` item per matching host unit, in `persons`' own order
  (`WeddingPlanner.Guests.list_persons/1`'s default name sort, same as `/people`'s flat
  view). `:grouped` — a `{:group_header, group, shown_count}` per
  `WeddingPlanner.Guests.list_groups/0` group (always rendered, even with zero shown
  members — the same convention `WeddingPlannerWeb.Live.PeopleLive` uses), its matching
  units, then a trailing `{:group_header, :ungrouped, shown_count}` section. A group's
  membership is decided by the **host's own** `group_id` (a +1 has none of its own,
  `DR-32`) — every +1 simply rides along inside its host's unit, never filtered into a
  group independently.

  ## Cells

  `{:unit, host, plus_ones, cells}`'s `cells` is `%{person_id => %{event_id => %{status:,
  opted_out:}}}` for **every** member of the unit (host included, `opted_out` always
  `false` there since only a +1 can opt out, `PER-13`) — covers both a host's own select
  and a +1's derived status plus its opt-out toggle in one shared shape.
  """

  alias WeddingPlanner.Events.Event
  alias WeddingPlanner.Guests.Group
  alias WeddingPlanner.Guests.Person
  alias WeddingPlanner.Guests.PlusOne
  alias WeddingPlanner.Invitations.Effective

  @type filters :: %{
          optional(:text) => String.t() | nil,
          optional(:want_tier) => Person.want_tier() | nil,
          optional(:event_id) => term() | nil,
          optional(:status) => Effective.status() | nil
        }

  @type grouping :: :flat | :grouped

  @type cell :: %{status: Effective.status(), opted_out: boolean()}
  @type cells :: %{optional(term()) => %{optional(term()) => cell()}}

  @type item ::
          {:group_header, Group.t() | :ungrouped, non_neg_integer()}
          | {:unit, Person.t(), [Person.t()], cells()}

  @type result :: %{items: [item()], shown: non_neg_integer(), total: non_neg_integer()}

  @doc """
  Turns a flat, already host-unit-ordered person list (`WeddingPlanner.Guests.list_persons/1`)
  into `{host, plus_ones}` pairs, `plus_ones` in the order they appeared. See the
  moduledoc for why this is an explicit walk, not `Enum.group_by/2`.

  ## Examples

      iex> alias WeddingPlanner.Invitations.Matrix
      iex> anna = %{id: 1, host_id: nil}
      iex> plus_one = %{id: 2, host_id: 1}
      iex> ben = %{id: 3, host_id: nil}
      iex> Matrix.host_units([anna, plus_one, ben])
      [{%{id: 1, host_id: nil}, [%{id: 2, host_id: 1}]}, {%{id: 3, host_id: nil}, []}]
  """
  @spec host_units([Person.t()]) :: [{Person.t(), [Person.t()]}]
  def host_units(persons) when is_list(persons) do
    persons
    |> Enum.reduce([], &place_person/2)
    |> Enum.reverse()
    |> Enum.map(fn {host, plus_ones} -> {host, Enum.reverse(plus_ones)} end)
  end

  defp place_person(person, acc) do
    if Person.plus_one?(person) do
      attach_plus_one(person, acc)
    else
      [{person, []} | acc]
    end
  end

  defp attach_plus_one(person, [{host, plus_ones} | rest]) when host.id == person.host_id do
    [{host, [person | plus_ones]} | rest]
  end

  defp attach_plus_one(person, _acc) do
    raise ArgumentError,
          "WeddingPlanner.Invitations.Matrix.host_units/1 expects every +1 to " <>
            "immediately follow its own host (person id=#{inspect(person.id)}, " <>
            "host_id=#{inspect(person.host_id)}) — got persons out of " <>
            "WeddingPlanner.Guests.list_persons/1's host-unit order (DR-34)"
  end

  @doc """
  The host units (see `host_units/1`) that pass `filters` — the shared filtering step
  behind `build/6`, exposed on its own so a caller (the group bulk action) can ask
  "which persons does the screen currently show" without also paying for grouping.
  """
  @spec matching_units([Person.t()], Effective.lookup(), filters()) :: [
          {Person.t(), [Person.t()]}
        ]
  def matching_units(persons, lookup, filters) when is_list(persons) do
    active = active_filters(filters)

    persons
    |> host_units()
    |> Enum.filter(&unit_matches?(&1, active, lookup))
  end

  @doc """
  Builds the ordered item list for the matrix (see the moduledoc). `persons` is
  `WeddingPlanner.Guests.list_persons/1`'s result, `groups` is
  `WeddingPlanner.Guests.list_groups/0`'s, `events` is
  `WeddingPlanner.Events.list_events/0`'s (already `EVT-04` order — never re-sorted
  here), `lookup` is `WeddingPlanner.Invitations.Effective.index/3`'s result.
  """
  @spec build([Person.t()], [Group.t()], [Event.t()], Effective.lookup(), filters(), grouping()) ::
          result()
  def build(persons, groups, events, lookup, filters, grouping)
      when is_list(persons) and is_list(groups) and is_list(events) and
             grouping in [:flat, :grouped] do
    total = persons |> host_units() |> length()
    matching = matching_units(persons, lookup, filters)

    items =
      case grouping do
        :flat -> Enum.map(matching, &to_item(&1, events, lookup))
        :grouped -> build_grouped_items(matching, groups, events, lookup)
      end

    %{items: items, shown: length(matching), total: total}
  end

  @doc """
  Builds a single `{:unit, host, plus_ones, cells}` item — the re-render-discipline
  path a single cell or opt-out change uses to `stream_insert/3` just the one affected
  host unit instead of resetting the whole matrix (see the LiveView's moduledoc).
  """
  @spec item_for_unit(Person.t(), [Person.t()], [Event.t()], Effective.lookup()) :: item()
  def item_for_unit(%Person{} = host, plus_ones, events, lookup)
      when is_list(plus_ones) and is_list(events) do
    to_item({host, plus_ones}, events, lookup)
  end

  # -- grouping ----------------------------------------------------------------------------

  defp build_grouped_items(units, groups, events, lookup) do
    grouped_sections =
      Enum.flat_map(groups, fn group ->
        members = Enum.filter(units, fn {host, _plus_ones} -> host.group_id == group.id end)
        group_section(group, members, events, lookup)
      end)

    ungrouped_members = Enum.filter(units, fn {host, _plus_ones} -> is_nil(host.group_id) end)

    grouped_sections ++ group_section(:ungrouped, ungrouped_members, events, lookup)
  end

  defp group_section(group_or_ungrouped, members, events, lookup) do
    [
      {:group_header, group_or_ungrouped, length(members)}
      | Enum.map(members, &to_item(&1, events, lookup))
    ]
  end

  # -- cells -------------------------------------------------------------------------------

  defp to_item({host, plus_ones}, events, lookup) do
    {:unit, host, plus_ones, unit_cells(host, plus_ones, events, lookup)}
  end

  defp unit_cells(host, plus_ones, events, lookup) do
    for person <- [host | plus_ones], into: %{} do
      {person.id, event_cells(person, events, lookup)}
    end
  end

  defp event_cells(person, events, lookup) do
    for event <- events, into: %{} do
      status = Effective.status(lookup, person, event.id)
      opted_out = Person.plus_one?(person) and Effective.opted_out?(lookup, person, event.id)
      {event.id, %{status: status, opted_out: opted_out}}
    end
  end

  # -- filtering (DR-34's "any member matches every active filter") -----------------------

  defp active_filters(filters) do
    []
    |> maybe_add(:text, normalize_text(Map.get(filters, :text)))
    |> maybe_add(:want_tier, Map.get(filters, :want_tier))
    |> maybe_add_status_for_event(Map.get(filters, :event_id), Map.get(filters, :status))
  end

  defp maybe_add(list, _key, nil), do: list
  defp maybe_add(list, key, value), do: [{key, value} | list]

  defp maybe_add_status_for_event(list, event_id, status)
       when not is_nil(event_id) and not is_nil(status) do
    [{:status_for_event, {event_id, status}} | list]
  end

  defp maybe_add_status_for_event(list, _event_id, _status), do: list

  defp normalize_text(nil), do: nil
  defp normalize_text(""), do: nil
  defp normalize_text(text), do: text |> String.trim() |> String.downcase()

  defp unit_matches?(_unit, [], _lookup), do: true

  defp unit_matches?({host, plus_ones}, active, lookup) do
    Enum.any?([host | plus_ones], &person_matches_all?(&1, host, active, lookup))
  end

  defp person_matches_all?(person, host, active, lookup) do
    Enum.all?(active, &person_matches?(person, host, &1, lookup))
  end

  defp person_matches?(person, _host, {:text, text}, _lookup) do
    person |> Person.display_name() |> String.downcase() |> String.contains?(text)
  end

  defp person_matches?(person, host, {:want_tier, value}, _lookup) do
    PlusOne.want_tier(person, host) == value
  end

  defp person_matches?(person, _host, {:status_for_event, {event_id, status}}, lookup) do
    Effective.status(lookup, person, event_id) == status
  end
end
