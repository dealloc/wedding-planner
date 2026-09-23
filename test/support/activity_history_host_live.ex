defmodule WeddingPlannerWeb.ActivityHistoryHostLiveTestSupport do
  @moduledoc """
  Minimal host LiveView reproducing `WeddingPlannerWeb.ActivityComponents.entity_history/1`'s
  documented "Host LiveView pattern" verbatim, scoped to `{:person, id}` — used only by
  `WeddingPlannerWeb.ActivityComponentsTest` via `Phoenix.LiveViewTest.live_isolated/3`.
  Kept in `test/support` (a real top-level module, not nested) so `use WeddingPlannerWeb,
  :live_view`'s `Phoenix.Component.assign/3` import does not collide with `ConnCase`'s
  `Plug.Conn.assign/3` import in the test file that uses it.
  """
  use WeddingPlannerWeb, :live_view

  alias WeddingPlanner.Log.Query
  alias WeddingPlanner.Realtime

  @impl true
  def mount(_params, %{"id" => id}, socket) do
    if connected?(socket), do: Realtime.subscribe(:activity_entry)

    {:ok,
     socket
     |> assign(:entity_id, id)
     |> assign(:activity_entries, Query.for_entity(:person, id))}
  end

  @impl true
  def handle_info({Realtime, :activity_entry, {:created, entry}}, socket) do
    if entry.entity_type == "person" and entry.entity_id == socket.assigns.entity_id do
      entry = Query.preload_user(entry)
      {:noreply, update(socket, :activity_entries, &[entry | &1])}
    else
      {:noreply, socket}
    end
  end

  @impl true
  def render(assigns) do
    ~H"""
    <WeddingPlannerWeb.ActivityComponents.entity_history
      id="person-history"
      entity={{:person, @entity_id}}
      entries={@activity_entries}
    />
    """
  end
end
