defmodule WeddingPlannerWeb.Live.TimeZoneHookTest do
  use WeddingPlannerWeb.ConnCase, async: true

  import Phoenix.LiveViewTest

  alias WeddingPlannerWeb.Format
  alias WeddingPlannerWeb.Live.TimeZoneHook

  # A minimal LiveView used only by this test to exercise `on_mount/4` and `probe/1`
  # without needing a routed LiveView (none exists yet — this is foundational
  # infrastructure for a future feature, per the "one feature at a time" working
  # agreement).
  defmodule ProbeLive do
    use Phoenix.LiveView

    on_mount {WeddingPlannerWeb.Live.TimeZoneHook, :default}

    @impl true
    def mount(_params, _session, socket), do: {:ok, socket}

    @impl true
    def render(assigns) do
      ~H"""
      <TimeZoneHook.probe id="time-zone-probe" />
      <span id="zone">{@time_zone}</span>
      """
    end
  end

  describe "on_mount/4 — NFR-22" do
    test "assigns the configured default time zone before the browser reports in", %{conn: conn} do
      {:ok, view, html} = live_isolated(conn, ProbeLive)

      assert html =~ Format.default_time_zone()
      assert render(view) =~ Format.default_time_zone()
    end

    test "updates the time zone once the client-side hook reports a valid IANA zone", %{
      conn: conn
    } do
      {:ok, view, _html} = live_isolated(conn, ProbeLive)

      html = render_hook(view, "time_zone", %{"zone" => "America/New_York"})
      assert html =~ "America/New_York"
    end

    test "keeps the configured default when the client reports an unparseable zone", %{
      conn: conn
    } do
      {:ok, view, _html} = live_isolated(conn, ProbeLive)

      html = render_hook(view, "time_zone", %{"zone" => "not a real zone"})
      assert html =~ Format.default_time_zone()
    end

    test "keeps the configured default when the client reports nothing usable (nil zone)", %{
      conn: conn
    } do
      {:ok, view, _html} = live_isolated(conn, ProbeLive)

      html = render_hook(view, "time_zone", %{"zone" => nil})
      assert html =~ Format.default_time_zone()
    end
  end

  describe "probe/1 — colocated hook wiring" do
    test "renders a unique DOM id and the colocated hook attribute" do
      html = render_component(&TimeZoneHook.probe/1, id: "time-zone-probe")

      assert html =~ ~s(id="time-zone-probe")
      # The source names the hook ".TimeZone" (dot-prefixed, per AGENTS.md); LiveView
      # resolves that to the fully-qualified name at compile time in the rendered
      # attribute and in the generated JS manifest.
      assert html =~ ~s(phx-hook="WeddingPlannerWeb.Live.TimeZoneHook.TimeZone")
    end
  end
end
