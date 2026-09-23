defmodule WeddingPlannerWeb.Live.PasskeyCeremonyTest do
  use WeddingPlannerWeb.ConnCase, async: true

  import Phoenix.LiveViewTest

  alias WeddingPlannerWeb.Live.PasskeyCeremony

  # A minimal LiveView used only by this test to render `ceremony/1` in a real LiveView
  # tree (task 13 has no routed LiveView of its own yet — tasks 14/15 host it).
  defmodule HostLive do
    use Phoenix.LiveView

    alias WeddingPlannerWeb.Live.PasskeyCeremony

    @impl true
    def mount(_params, _session, socket), do: {:ok, socket}

    @impl true
    def render(assigns) do
      ~H"""
      <PasskeyCeremony.ceremony id="passkey-ceremony" />
      """
    end
  end

  describe "ceremony/1 — colocated hook wiring" do
    test "renders the hook element with its DOM id and phx-hook attribute", %{conn: conn} do
      {:ok, view, _html} = live_isolated(conn, HostLive)

      assert has_element?(view, "#passkey-ceremony[phx-hook]")
    end

    test "resolves the hook name to the fully-qualified colocated hook", %{conn: conn} do
      {:ok, view, _html} = live_isolated(conn, HostLive)

      # The source names the hook ".PasskeyCeremony" (dot-prefixed, per AGENTS.md);
      # LiveView resolves that to the fully-qualified name at compile time.
      assert has_element?(
               view,
               ~s(#passkey-ceremony[phx-hook="WeddingPlannerWeb.Live.PasskeyCeremony.PasskeyCeremony"])
             )
    end

    test "defaults to the \"passkey-ceremony\" id when none is given" do
      html = render_component(&PasskeyCeremony.ceremony/1, %{})
      document = LazyHTML.from_fragment(html)

      assert LazyHTML.filter(document, "#passkey-ceremony[phx-hook]") != []
    end
  end
end
