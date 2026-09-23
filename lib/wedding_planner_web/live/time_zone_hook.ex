defmodule WeddingPlannerWeb.Live.TimeZoneHook do
  @moduledoc """
  Reports the viewer's browser time zone to the server, for `WeddingPlannerWeb.Format.datetime/2`
  (`NFR-22`).

  ## Usage

  Attach the `on_mount` callback in any LiveView (or in a `live_session`'s `on_mount` list)
  that needs to display a `DateTime` in the viewer's local time:

      defmodule WeddingPlannerWeb.SomeLive do
        use WeddingPlannerWeb, :live_view

        on_mount {WeddingPlannerWeb.Live.TimeZoneHook, :default}

        def render(assigns) do
          ~H\"""
          <WeddingPlannerWeb.Live.TimeZoneHook.probe id="time-zone-probe" />
          {WeddingPlannerWeb.Format.datetime(@some_utc_timestamp, @time_zone)}
          \"""
        end
      end

  `on_mount/4` assigns `@time_zone` immediately, defaulting to
  `WeddingPlannerWeb.Format.default_time_zone/0` — so the very first render (including the
  static, pre-connection one) already has a usable value. Once the client connects and
  `probe/1`'s colocated hook reports in, `@time_zone` is updated to the browser's zone (or
  left at the default if the browser reported nothing usable — `resolve_time_zone/1` is
  total and never raises).

  Render `probe/1` at most once per LiveView; it carries no visible content.
  """

  use Phoenix.Component

  alias WeddingPlannerWeb.Format

  @doc """
  Renders the invisible element that reports the browser's IANA time zone on connect.

  Give it a unique DOM id, as required for `phx-hook`.
  """
  attr :id, :string, default: "time-zone-probe"

  def probe(assigns) do
    ~H"""
    <span id={@id} phx-hook=".TimeZone" hidden></span>
    <script :type={Phoenix.LiveView.ColocatedHook} name=".TimeZone">
      export default {
        mounted() {
          let zone = null

          try {
            zone = Intl.DateTimeFormat().resolvedOptions().timeZone || null
          } catch (_error) {
            zone = null
          }

          this.pushEvent("time_zone", {zone})
        }
      }
    </script>
    """
  end

  @doc false
  def on_mount(:default, _params, _session, socket) do
    socket =
      socket
      |> Phoenix.Component.assign_new(:time_zone, fn -> Format.default_time_zone() end)
      |> Phoenix.LiveView.attach_hook(
        :time_zone_probe,
        :handle_event,
        &__MODULE__.handle_time_zone_event/3
      )

    {:cont, socket}
  end

  @doc false
  def handle_time_zone_event("time_zone", params, socket) do
    zone = Map.get(params, "zone")
    {:halt, Phoenix.Component.assign(socket, :time_zone, Format.resolve_time_zone(zone))}
  end

  def handle_time_zone_event(_event, _params, socket), do: {:cont, socket}
end
