defmodule WeddingPlannerWeb.Layouts do
  @moduledoc """
  This module holds layouts and related functionality
  used by your application.
  """
  use WeddingPlannerWeb, :html

  # Embed all files in layouts/* within this module.
  # The default root.html.heex file contains the HTML
  # skeleton of your application, namely HTML headers
  # and other static content.
  embed_templates "layouts/*"

  @doc """
  Renders your app layout.

  This function is typically invoked from every template,
  and it often contains your application menu, sidebar,
  or similar.

  ## Examples

      <Layouts.app flash={@flash}>
        <h1>Content</h1>
      </Layouts.app>

  ## Width

  The content column defaults to a centered `max-w-2xl`, which is right for forms and
  most lists. Pass `width="wide"` (`max-w-6xl`) only for screens that are genuinely
  tabular or master–detail — e.g. a multi-column data table with many rows, or a
  desktop master–detail split — where the narrow column would waste space or squeeze
  a wide header row. Everything else keeps the default:

      <Layouts.app flash={@flash} width="wide">
        <h1>A wide table or master-detail screen</h1>
      </Layouts.app>

  """
  attr :flash, :map, required: true, doc: "the map of flash messages"

  attr :current_scope, :map,
    default: nil,
    doc: "the current [scope](https://phoenix.hexdocs.pm/scopes.html)"

  attr :width, :string,
    values: ["default", "wide"],
    default: "default",
    doc: """
    the content column width: "default" (max-w-2xl) for forms and most lists, or
    "wide" (max-w-6xl) for tabular/master-detail screens with many columns or rows
    """

  slot :inner_block, required: true

  def app(assigns) do
    assigns = assign(assigns, :nav_entries, nav_entries())

    ~H"""
    <header class="border-b border-line">
      <div class="flex flex-col gap-3 px-4 py-3 sm:flex-row sm:items-center sm:justify-between sm:gap-6 sm:px-6 lg:px-8">
        <a href="/" class="inline-flex items-center gap-2">
          <span class="text-base font-bold tracking-tight text-ink">Wedding Planner</span>
        </a>

        <nav id="main-nav" aria-label="Main">
          <ul class="flex flex-wrap items-center gap-1 sm:gap-2">
            <li :for={entry <- @nav_entries} id={"nav-#{entry.id}"}>
              <.link
                navigate={entry.path}
                class="flex min-h-11 items-center rounded-field px-3 text-base font-medium text-ink-soft transition hover:bg-surface hover:text-ink sm:min-h-0 sm:py-1.5 sm:text-sm"
              >
                {entry.label}
              </.link>
            </li>
            <li :if={@current_scope && @current_scope.user}>
              <.link
                href={~p"/session"}
                method="delete"
                id="sign-out"
                class="flex min-h-11 items-center rounded-field px-3 text-base font-medium text-ink-soft transition hover:bg-surface hover:text-ink sm:min-h-0 sm:py-1.5 sm:text-sm"
              >
                Sign out
              </.link>
            </li>
          </ul>
        </nav>
      </div>
    </header>

    <main class="px-4 py-10 sm:px-6 lg:px-8">
      <div
        id="main-content"
        class={[
          "mx-auto space-y-4",
          @width == "wide" && "max-w-6xl",
          @width != "wide" && "max-w-2xl"
        ]}
      >
        {render_slot(@inner_block)}
      </div>
    </main>

    <.flash_group flash={@flash} />
    """
  end

  # The navigation data list (comfortable-dense at >= sm, spacious 44px tap
  # targets below it — see `app/1`'s markup for the responsive classes, not
  # duplicated here).
  #
  # Every later slice adds its screen to the nav with exactly one line
  # appended below, e.g.:
  #
  #     %{id: "people", label: "People", path: ~p"/people"},
  #
  # `id` becomes the `nav-#{id}` DOM id on the `<li>` (see `app/1`), so give
  # it a short, stable, kebab-case-friendly atom-ish string — it is never
  # shown to the user.
  defp nav_entries do
    [
      %{id: "home", label: "Home", path: ~p"/home"},
      %{id: "events", label: "Events", path: ~p"/events"},
      %{id: "activity", label: "Activity", path: ~p"/activity"},
      %{id: "enrollment-links", label: "Enrollment", path: ~p"/enrollment-links"},
      %{id: "devices", label: "Devices", path: ~p"/devices"},
      %{id: "settings", label: "Settings", path: ~p"/settings"}
    ]
  end

  @doc """
  Shows the flash group with standard titles and content.

  ## Examples

      <.flash_group flash={@flash} />
  """
  attr :flash, :map, required: true, doc: "the map of flash messages"
  attr :id, :string, default: "flash-group", doc: "the optional id of flash container"

  def flash_group(assigns) do
    ~H"""
    <div id={@id} aria-live="polite">
      <.flash kind={:info} flash={@flash} />
      <.flash kind={:error} flash={@flash} />

      <.flash
        id="client-error"
        kind={:error}
        title="We can't find the internet"
        phx-disconnected={
          show(".phx-client-error #client-error")
          |> JS.remove_attribute("hidden", to: ".phx-client-error #client-error")
        }
        phx-connected={hide("#client-error") |> JS.set_attribute({"hidden", ""})}
        hidden
      >
        Attempting to reconnect
        <.icon name="hero-arrow-path" class="ml-1 size-3 motion-safe:animate-spin" />
      </.flash>

      <.flash
        id="server-error"
        kind={:error}
        title="Something went wrong!"
        phx-disconnected={
          show(".phx-server-error #server-error")
          |> JS.remove_attribute("hidden", to: ".phx-server-error #server-error")
        }
        phx-connected={hide("#server-error") |> JS.set_attribute({"hidden", ""})}
        hidden
      >
        Attempting to reconnect
        <.icon name="hero-arrow-path" class="ml-1 size-3 motion-safe:animate-spin" />
      </.flash>
    </div>
    """
  end
end
