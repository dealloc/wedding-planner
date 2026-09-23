defmodule WeddingPlannerWeb.ReferencesHostLiveTestSupport do
  @moduledoc """
  Minimal host LiveView for `WeddingPlannerWeb.ReferencesComponent` (task 40, `DR-31`),
  reproducing the component's own documented "host" contract verbatim: mounts with a
  real owner (`DR-28`, `WeddingPlanner.ReferenceFixtures.owner/0` — a freshly inserted
  offer), loads
  `WeddingPlanner.References.list_references/1`, subscribes to
  `WeddingPlanner.Realtime.topic(:reference)` and reloads on every broadcast (`XC-01`).

  Used only by `WeddingPlannerWeb.ReferencesComponentTest` via
  `Phoenix.LiveViewTest.live_isolated/3` — there is no router entry and no production
  host page yet (B1 has no standalone demo; it is demoed with C2). Kept in
  `test/support` (a real top-level module, not nested) so `use WeddingPlannerWeb,
  :live_view`'s `Phoenix.Component.assign/3` import does not collide with `ConnCase`'s
  `Plug.Conn.assign/3` import in the test file that uses it — same reasoning as
  `test/support/activity_history_host_live.ex`.
  """
  use WeddingPlannerWeb, :live_view

  alias WeddingPlanner.References
  alias WeddingPlanner.Realtime
  alias WeddingPlannerWeb.ReferencesComponent

  @impl true
  def mount(_params, %{"owner" => owner, "scope" => scope}, socket) do
    if connected?(socket), do: Realtime.subscribe(:reference)

    {:ok,
     socket
     |> assign(:owner, owner)
     |> assign(:current_scope, scope)
     |> assign(:references, References.list_references(owner))}
  end

  @impl true
  def handle_info({Realtime, :reference, _event}, socket) do
    {:noreply, assign(socket, :references, References.list_references(socket.assigns.owner))}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <.live_component
      module={ReferencesComponent}
      id="refs"
      owner={@owner}
      references={@references}
      current_scope={@current_scope}
    />
    """
  end
end
