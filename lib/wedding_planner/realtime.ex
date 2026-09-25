defmodule WeddingPlanner.Realtime do
  @moduledoc """
  The one PubSub convention every context follows so both users see each
  other's changes live (`XC-01`), without needing to invent topic naming or
  message shapes per module.

  This module is intentionally small: a topic-naming scheme, `subscribe/1,2`,
  and `broadcast_change/2`. There is no per-field diffing, no "who changed
  this" metadata and no conflict detection — see the `XC-02` section below for
  why that is deliberate, not an oversight.

  ## Topic naming

  Every topic is prefixed `"wp:"` so it reads unambiguously as this app's own
  convention next to LiveView's internal PubSub traffic (the endpoint's
  `:pubsub_server` is the same `WeddingPlanner.PubSub` process LiveView uses
  for its own channel transport).

  Two shapes exist, built by `topic/1` and `topic/2`:

    * `topic(:person)` -> `"wp:person"` — the **collection** topic for a
      resource. Subscribe to this from any view that lists or otherwise cares
      about *any* change to that resource (an index page, a matrix, the
      activity log screen).
    * `topic(:person, 42)` -> `"wp:person:42"` — the **record** topic for one
      specific row. Subscribe to this from a detail/edit view that only cares
      about the one record it is showing, so it does not re-render on
      unrelated rows changing.

  `resource` is a short atom naming the domain concept as callers think about
  it, not necessarily the Ecto schema module — e.g. `:person`, `:offer`,
  `:invoice`, `:task`, `:activity_entry`. Pick the same atom everywhere for a
  given resource; it only has meaning as a string key on the PubSub server, so
  a typo silently creates a dead topic rather than raising.

  ## Message shape

  `broadcast_change/2` always sends the 3-tuple

      {WeddingPlanner.Realtime, resource, event}

  where `event` is one of:

    * `{:created, record}`
    * `{:updated, record}`
    * `{:deleted, id}`

  `record` is the **whole** struct after the write (see `XC-02` below) — never
  a diff, never just the changed fields. Matching on the leading module atom
  in `handle_info/2` keeps this unambiguous from any other message a LiveView
  process might receive:

      def handle_info({WeddingPlanner.Realtime, :person, {:updated, person}}, socket) do
        {:noreply, stream_insert(socket, :people, person)}
      end

  ## The `XC-02` convention: last write wins, no conflict UI

  Concurrent edits resolve as **last write wins, per field** — there is no
  locking and no merge UI (`XC-02`), and the user has explicitly rejected any
  "someone else changed this" affordance: *"no need for tracking concurrent
  edits, me and my partner literally talk to each other."* Concretely, this
  means every context function:

    1. Writes with an **ordinary changeset** (`Repo.insert/2`, `Repo.update/2`,
       `Repo.delete/2`) — no optimistic-lock version column, no diffing
       against what the editor last read.
    2. Broadcasts the **whole resulting record** via `broadcast_change/2` —
       never a partial payload, because there is no conflict UI that would
       need to know which fields changed.
    3. Does **not** build, and must not grow, a "someone else is editing this"
       notice, a stale-data warning, a color change or badge marking what
       changed, or any other concurrent-edit indicator UI. This was decided
       with the user directly, not just inferred from `XC-02`: given the
       choice between an inline "updated just now" notice, an app-wide toast,
       or nothing at all, the user chose nothing. Content driven by a
       broadcast simply updates in place, exactly as if the viewer had
       reloaded the page — there is no affordance calling attention to the
       fact that it changed.

  `WeddingPlanner`'s activity log (`XC-10`–`XC-13`) remains the only
  after-the-fact record of who changed what; it is written synchronously
  alongside the domain write (not derived from these broadcasts) and is a
  resource in its own right — a live activity-log screen subscribes to
  `topic(:activity_entry)` like any other resource.

  ## The `:data_import` resource (`DR-95`)

  A data import (`DR-93`) replaces every transferred table at once, so no single
  resource's `{:created | :updated, struct}` / `{:deleted, id}` shape fits. It gets its
  own collection-only topic instead: `broadcast_change(:data_import, {:created, %{origin:
  pid() | nil, exported_at: DateTime.t(), source_host: String.t()}})`, sent once the
  import transaction commits. `WeddingPlannerWeb.Live.ReloadOnImportHook` is the sole
  subscriber, attached centrally to every authenticated `live_session` LiveView; see its
  moduledoc for how it turns that one message into "every open screen but the importer's
  reloads its data".

  ## Usage

  Subscribing (typically in `mount/3`, guarded by `connected?/1` so the
  static/disconnected render does not attempt a subscription):

      def mount(_params, _session, socket) do
        if connected?(socket), do: WeddingPlanner.Realtime.subscribe(:person)
        {:ok, assign(socket, :people, Guests.list_people())}
      end

  Broadcasting after an ordinary write, from the context module that owns the
  resource:

      def update_person(%Person{} = person, attrs) do
        person
        |> Person.changeset(attrs)
        |> Repo.update()
        |> case do
          {:ok, person} ->
            WeddingPlanner.Realtime.broadcast_change(:person, {:updated, person})
            {:ok, person}

          error ->
            error
        end
      end
  """

  alias Phoenix.PubSub

  @pubsub WeddingPlanner.PubSub
  @prefix "wp"

  @type resource :: atom()
  @type event :: {:created, struct()} | {:updated, struct()} | {:deleted, term()}

  @doc """
  Builds the collection-level topic for `resource`, e.g. `topic(:person)` ->
  `"wp:person"`.
  """
  @spec topic(resource()) :: String.t()
  def topic(resource) when is_atom(resource), do: "#{@prefix}:#{resource}"

  @doc """
  Builds the record-level topic for one `resource` identified by `id`, e.g.
  `topic(:person, 42)` -> `"wp:person:42"`.
  """
  @spec topic(resource(), term()) :: String.t()
  def topic(resource, id) when is_atom(resource), do: "#{@prefix}:#{resource}:#{id}"

  @doc """
  Subscribes the calling process to every change on `resource` (the
  collection topic).
  """
  @spec subscribe(resource()) :: :ok | {:error, term()}
  def subscribe(resource) when is_atom(resource) do
    PubSub.subscribe(@pubsub, topic(resource))
  end

  @doc """
  Subscribes the calling process to changes on one specific `resource`
  record (the record topic).
  """
  @spec subscribe(resource(), term()) :: :ok | {:error, term()}
  def subscribe(resource, id) when is_atom(resource) do
    PubSub.subscribe(@pubsub, topic(resource, id))
  end

  @doc "The inverse of `subscribe/1`."
  @spec unsubscribe(resource()) :: :ok
  def unsubscribe(resource) when is_atom(resource) do
    PubSub.unsubscribe(@pubsub, topic(resource))
  end

  @doc "The inverse of `subscribe/2`."
  @spec unsubscribe(resource(), term()) :: :ok
  def unsubscribe(resource, id) when is_atom(resource) do
    PubSub.unsubscribe(@pubsub, topic(resource, id))
  end

  @doc """
  Broadcasts a whole-record change for `resource` (`XC-02` — never a diff).

  Sends `{#{inspect(__MODULE__)}, resource, event}` to both the collection
  topic (`topic(resource)`) and, when the event carries an identifiable
  record, the record topic (`topic(resource, id)`) — so a detail view
  subscribed only to its own record still hears about it.

  The id is read from `record.id` for `{:created, record}` and
  `{:updated, record}`, and used directly for `{:deleted, id}`. If a
  `{:created, record}` / `{:updated, record}` payload has no `:id` field (or
  is not a struct/map), only the collection topic is notified — this is a
  supported use for non-persisted/demo events, not an error.
  """
  @spec broadcast_change(resource(), event()) :: :ok
  def broadcast_change(resource, {action, _payload} = event)
      when is_atom(resource) and action in [:created, :updated, :deleted] do
    :ok = PubSub.broadcast(@pubsub, topic(resource), {__MODULE__, resource, event})

    case record_id(event) do
      nil -> :ok
      id -> PubSub.broadcast(@pubsub, topic(resource, id), {__MODULE__, resource, event})
    end
  end

  defp record_id({:deleted, id}), do: id
  defp record_id({_action, %{id: id}}), do: id
  defp record_id({_action, _payload}), do: nil
end
