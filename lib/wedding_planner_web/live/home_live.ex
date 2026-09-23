defmodule WeddingPlannerWeb.HomeLive do
  @moduledoc """
  Minimal placeholder screen hosting the application shell (`Layouts.app`)
  and demonstrating the `WeddingPlanner.Realtime` live-update convention this
  slice establishes (`XC-01`, `XC-02`).

  This is scaffolding, not a feature. It exists so the shell/nav/PubSub
  conventions have one real, routed LiveView to mount in tests and to poke at
  by hand from `iex`. Expect it to be replaced by the real dashboard once
  that slice lands — swapping the nav's "Home" entry and the `/home` route
  over to the real thing is the same one-line nav-list edit this slice was
  built to make trivial (see `WeddingPlannerWeb.Layouts.nav_entries/0`).

  ## Trying the live update from `iex -S mix phx.server`

  With this page open in one or more browser tabs at `/home`:

      WeddingPlanner.Realtime.broadcast_change(:shell_demo, {:updated, %{message: "Cake tasting booked!"}})

  Every open tab's content updates immediately, no manual refresh. Per
  `XC-02` and the user's decision, that is the entire affordance — the
  content simply changes in place, with no color change, badge or any other
  indicator that something changed.
  """
  use WeddingPlannerWeb, :live_view

  alias WeddingPlanner.Realtime

  @resource :shell_demo

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket), do: Realtime.subscribe(@resource)

    socket =
      assign(
        socket,
        :demo_message,
        "Nothing broadcast yet — see this page's moduledoc for an iex one-liner."
      )

    {:ok, socket}
  end

  @impl true
  def handle_info({Realtime, @resource, {:updated, %{message: message}}}, socket) do
    {:noreply, assign(socket, :demo_message, message)}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash}>
      <.header>Wedding Planner</.header>

      <p class="text-sm text-ink-soft">
        This placeholder page hosts the application shell while the real screens are built.
      </p>

      <p
        id="shell-demo-message"
        class="rounded-field border border-line-strong bg-surface-raised px-4 py-3 text-sm text-ink"
      >
        {@demo_message}
      </p>
    </Layouts.app>
    """
  end
end
