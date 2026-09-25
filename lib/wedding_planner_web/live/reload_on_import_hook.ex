defmodule WeddingPlannerWeb.Live.ReloadOnImportHook do
  @moduledoc """
  Reloads every open authenticated screen after a data import replaces all data (task 100),
  so both users see live data everywhere without a manual refresh (`XC-01`) — one central
  `on_mount` hook rather than per-LiveView code (`DR-95`).

  ## Why this exists (`DR-95`)

  A data import (`DR-93`) deletes and re-inserts every transferred table in one transaction.
  The 83-plus `WeddingPlanner.Realtime.subscribe/1` call sites across the app each pattern-match
  a specific `{:created | :updated, struct}` / `{:deleted, id}` shape for *their* resource — an
  import can't reuse those without inventing a synthetic message per topic (and crashing any
  handler that tries to `stream_insert` a payload that isn't its struct). Nor can it disconnect
  every live socket (the sign-out mechanism): that would also reconnect the importing screen,
  losing its own success panel and safety-copy link.

  Instead, this hook is attached once, in `live_session :authenticated`'s `on_mount:` list
  (after `WeddingPlannerWeb.UserAuth`), so every current and future authenticated LiveView
  inherits it with no per-screen code:

    * On `mount/3` (only once connected — the static/disconnected render never subscribes),
      it subscribes to the dedicated `:data_import` collection topic
      (`WeddingPlanner.Realtime.topic(:data_import)`).
    * It attaches a `:handle_params` hook that records the LiveView's current path plus query
      string (see "Capturing the current path" below).
    * It attaches a `:handle_info` hook. On
      `{WeddingPlanner.Realtime, :data_import, {:created, %{origin: origin}}}`:
        * if `origin == self()`, the message is swallowed (`{:halt, socket}`) — this is the
          screen that ran the import; it keeps showing its own result, per `XC-02`/`DR-21`'s
          "no concurrent-edit indicator" rule (no flash, no toast, nothing calling attention to
          the fact that everything just changed underneath it).
        * otherwise, the socket `push_navigate`s (`replace: true`) to its own current URL. This
          is a live navigation: it remounts the LiveView (and its live components) from scratch
          against the post-import data, while keeping the browser on the same URL. There is no
          flash, no "data was replaced" banner — content simply updates in place, exactly as if
          the viewer had reloaded the page (`XC-02`, `DR-21`). The activity log is the only
          after-the-fact record of the import (`DR-98`).
    * Any other `:data_import` payload shape halts silently (defensive; the only shape task 100
      ever sends is `{:created, %{origin: ..., exported_at: ..., source_host: ...}}}`).
    * **Every other message** — any other resource's `Realtime` broadcast, or anything else the
      process receives — is passed through untouched (`{:cont, socket}`), so each LiveView's own
      `handle_info/2` keeps working exactly as before.

  ## Capturing the current path

  The hook needs the LiveView's current URL (path + query) to `push_navigate` back to it. The
  `:handle_params` lifecycle stage runs on every mount and every `handle_params`-triggered patch,
  and — importantly — **still runs even when the LiveView itself does not define
  `handle_params/3`** (several authenticated screens don't, e.g. `SettingsLive`,
  `HomeLive`, `DevicesLive`): `Phoenix.LiveView.Lifecycle.stage_info/4` treats a stage as active
  (`any?: true`) when *either* the view exports the callback *or* any hook is attached for it,
  and hooks attached during `on_mount` (this one included) are already registered by the time
  that check runs for the initial mount. This was verified against `phoenix_live_view` 1.2.11's
  source (`lifecycle.ex`, `channel.ex`, `static.ex`) and by hand: `GET /settings` (no
  `handle_params/3` of its own) still gets `@reload_on_import_path` assigned, and this module's
  test suite mounts `/settings` live to prove the redirect fires from it. So no
  `get_connect_info`/`socket.host_uri`-based fallback is needed.

  The assign is namespaced `:reload_on_import_path` so no LiveView's own assigns collide with it.

  ## The vanished-record edge case

  If the importing user replaces data while a partner tab has a detail page open for a record
  that the import doesn't recreate (e.g. `/offers/12` when offer 12 no longer exists), the
  `push_navigate` remounts that same route and the LiveView's own `get!` raises exactly as it
  would for any other stale link today (a 404). This is accepted, not specially handled — see
  `DR-95`. Checked by hand: `/offers/<id that does not exist>` renders the app's ordinary 404,
  both with and without this hook involved.
  """

  import Phoenix.LiveView
  import Phoenix.Component, only: [assign: 3]

  alias WeddingPlanner.Realtime

  @assign :reload_on_import_path

  @doc false
  def on_mount(:default, _params, _session, socket) do
    if connected?(socket), do: Realtime.subscribe(:data_import)

    socket =
      socket
      |> attach_hook(:reload_on_import_uri, :handle_params, &track_uri/3)
      |> attach_hook(:reload_on_import, :handle_info, &handle_info/2)

    {:cont, socket}
  end

  defp track_uri(_params, uri, socket) do
    {:cont, assign(socket, @assign, path_with_query(uri))}
  end

  @doc false
  def handle_info({Realtime, :data_import, {:created, %{origin: origin}}}, socket) do
    if origin == self() do
      {:halt, socket}
    else
      path = Map.get(socket.assigns, @assign, "/home")
      {:halt, push_navigate(socket, to: path, replace: true)}
    end
  end

  def handle_info({Realtime, :data_import, _other}, socket), do: {:halt, socket}
  def handle_info(_msg, socket), do: {:cont, socket}

  defp path_with_query(uri) do
    %URI{path: path, query: query} = URI.parse(uri)
    path = path || "/"

    case query do
      nil -> path
      "" -> path
      query -> path <> "?" <> query
    end
  end
end
