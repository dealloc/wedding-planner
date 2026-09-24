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
    assigns =
      assigns
      |> assign(:primary_entries, Enum.filter(nav_entries(), &(&1.tier == :primary)))
      |> assign(:secondary_entries, Enum.filter(nav_entries(), &(&1.tier == :secondary)))

    ~H"""
    <header class="border-b border-line">
      <div class="flex flex-col gap-3 px-4 py-3 sm:px-6 md:flex-row md:items-center md:justify-between md:gap-6 lg:px-8">
        <div class="flex items-center justify-between gap-3">
          <a href="/" class="inline-flex items-center gap-2">
            <span class="text-base font-bold tracking-tight text-ink">Wedding Planner</span>
          </a>

          <button
            type="button"
            id="menu-toggle"
            aria-expanded="false"
            aria-controls="main-nav"
            class="flex min-h-11 items-center gap-1 rounded-field px-3 text-sm font-medium text-ink-soft transition hover:bg-surface hover:text-ink focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-accent md:hidden"
            phx-click={
              JS.toggle_class("hidden", to: "#main-nav")
              |> JS.toggle_attribute({"aria-expanded", "true", "false"})
            }
          >
            Menu <.icon name="hero-bars-3" class="size-5" />
          </button>
        </div>

        <nav
          id="main-nav"
          aria-label="Main"
          class="hidden flex-col gap-1 md:flex md:flex-row md:items-center md:gap-1"
          phx-window-keydown={close_mobile_nav_js()}
          phx-key="Escape"
        >
          <ul id="nav-primary" class="flex flex-col gap-1 md:flex-row md:items-center md:gap-1">
            <li :for={entry <- @primary_entries} id={"nav-#{entry.id}"}>
              <.link
                navigate={entry.path}
                phx-click={close_mobile_nav_js()}
                class="flex min-h-11 items-center rounded-field px-3 text-base font-medium text-ink-soft transition hover:bg-surface hover:text-ink md:min-h-0 md:py-1.5 md:text-sm"
              >
                {entry.label}
              </.link>
            </li>
          </ul>

          <div class="my-1 border-t border-line md:hidden"></div>

          <%!--
          < md: the secondary group renders flat, right here, with the canonical
          `nav-<id>`/`sign-out` ids — no extra "More" interaction needed once the panel
          itself is open. A native closed `<details>` unconditionally suppresses paint of
          its own non-summary children in current Chromium (the `::details-content`
          internals ignore a child's own `display` override, `!important` or not), so
          this list deliberately lives *outside* the `<details>` below rather than trying
          to force its content visible while collapsed.
          --%>
          <ul id="nav-secondary-mobile" class="flex flex-col gap-1 md:hidden">
            <li :for={entry <- @secondary_entries} id={"nav-#{entry.id}"}>
              <.link
                navigate={entry.path}
                phx-click={close_mobile_nav_js()}
                class="flex min-h-11 items-center rounded-field px-3 text-base font-medium text-ink-soft transition hover:bg-surface hover:text-ink"
              >
                {entry.label}
              </.link>
            </li>
            <li :if={@current_scope && @current_scope.user}>
              <.link
                href={~p"/session"}
                method="delete"
                id="sign-out"
                phx-click={close_mobile_nav_js()}
                class="flex min-h-11 items-center rounded-field px-3 text-base font-medium text-ink-soft transition hover:bg-surface hover:text-ink"
              >
                Sign out
              </.link>
            </li>
          </ul>

          <%!--
          >= md only: the same secondary group, behind a native, zero-JS "More"
          disclosure. A second render of the same entries (not reused from above) since
          the < md copy must stay outside `<details>` — see the note above.
          --%>
          <details class="group hidden md:relative md:block">
            <summary class="hidden cursor-pointer list-none items-center gap-1 rounded-field px-3 py-1.5 text-sm font-medium text-ink-soft transition hover:bg-surface hover:text-ink focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-accent md:flex">
              More <.icon name="hero-chevron-down" class="size-4 transition group-open:rotate-180" />
            </summary>

            <ul
              id="nav-secondary-desktop"
              class="hidden md:absolute md:right-0 md:z-10 md:mt-1 md:min-w-40 md:flex-col md:gap-0.5 md:rounded-field md:border md:border-line md:bg-surface-raised md:p-1 md:shadow-lg md:group-open:flex"
            >
              <li :for={entry <- @secondary_entries}>
                <.link
                  navigate={entry.path}
                  class="flex items-center rounded-field px-3 py-1.5 text-sm font-medium text-ink-soft transition hover:bg-surface hover:text-ink"
                >
                  {entry.label}
                </.link>
              </li>
              <li :if={@current_scope && @current_scope.user}>
                <.link
                  href={~p"/session"}
                  method="delete"
                  class="flex items-center rounded-field px-3 py-1.5 text-sm font-medium text-ink-soft transition hover:bg-surface hover:text-ink"
                >
                  Sign out
                </.link>
              </li>
            </ul>
          </details>
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

  # The navigation data list — two tiers (DR-60, task 71):
  #
  #   * `:primary` — the planning surfaces, always inline in the bar at >= md (and
  #     first, in order, in the < md panel).
  #   * `:secondary` — housekeeping, tucked behind the "More" disclosure at >= md (and
  #     listed after a divider in the < md panel). Sign out is a separate element
  #     (see `app/1`, a `method: :delete` link) but lives in this same group.
  #
  # Comfortable-dense at >= md, spacious 44px tap targets below it — see `app/1`'s
  # markup for the responsive classes, not duplicated here.
  #
  # Every later slice adds its screen to the nav with exactly one line appended to
  # the appropriate tier below, e.g.:
  #
  #     %{id: "people", label: "People", path: ~p"/people", tier: :primary},
  #
  # `id` becomes the `nav-#{id}` DOM id on the `<li>` (see `app/1`), so give it a
  # short, stable, kebab-case-friendly atom-ish string — it is never shown to the
  # user.
  defp nav_entries do
    [
      %{id: "home", label: "Home", path: ~p"/home", tier: :primary},
      %{id: "people", label: "People", path: ~p"/people", tier: :primary},
      %{id: "invitations", label: "Invitations", path: ~p"/invitations", tier: :primary},
      %{id: "headcount", label: "Headcount", path: ~p"/headcount", tier: :primary},
      %{id: "events", label: "Events", path: ~p"/events", tier: :primary},
      %{id: "categories", label: "Categories", path: ~p"/categories", tier: :primary},
      %{id: "invoices", label: "Invoices", path: ~p"/invoices", tier: :primary},
      %{id: "tasks", label: "Tasks", path: ~p"/tasks", tier: :primary},
      %{id: "timeline", label: "Timeline", path: ~p"/timeline", tier: :primary},
      %{id: "activity", label: "Activity", path: ~p"/activity", tier: :secondary},
      %{
        id: "enrollment-links",
        label: "Enrollment",
        path: ~p"/enrollment-links",
        tier: :secondary
      },
      %{id: "devices", label: "Devices", path: ~p"/devices", tier: :secondary},
      %{id: "settings", label: "Settings", path: ~p"/settings", tier: :secondary}
    ]
  end

  # Force-closes the < md nav panel and its "Menu" toggle's `aria-expanded`, whatever
  # their current state — used both on Escape (window-wide) and on every nav link
  # click, since a LiveView `navigate` re-renders the panel's markup but does not, by
  # itself, reset a class a previous client-side `JS` command already mutated.
  defp close_mobile_nav_js do
    JS.set_attribute({"aria-expanded", "false"}, to: "#menu-toggle")
    |> JS.add_class("hidden", to: "#main-nav")
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
