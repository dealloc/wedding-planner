defmodule WeddingPlannerWeb.Components.ExportComponents do
  @moduledoc """
  The one "Export CSV" link every owning screen renders (`XC-30`, `DR-87`, task 94):
  `/people`, `/events`, `/headcount`, `/categories`, `/invoices`, `/budget`, `/tasks`.

  This is a plain file download over HTTP — `GET /exports/:kind`, handled entirely by
  `WeddingPlannerWeb.ExportController` — never a LiveView `push_event`, `navigate` or
  `patch`, and never a `phx-click`: the link's own `href` + `download` attribute is the
  whole mechanism, so there is no server round trip to dim or disturb a screen's own
  loading state (`/budget`'s `BudgetComponents.loading_targets/0` never lists it).

  `?tz=` carries the viewer's browser time zone (the host LiveView's `@time_zone`,
  already assigned by `on_mount {WeddingPlannerWeb.Live.TimeZoneHook, :default}` on every
  one of the seven screens) so "today" in the file (overdue columns, the filename date)
  is the viewer's, not the server's default (`NFR-22`).

  Styling reuses the existing secondary link/button idiom (design record §2: outline,
  transparent fill) — never the accent, since exporting isn't a screen's primary action.

  ## Layout (`NFR-31`)

  One small inline link, placed as another sibling inside the screen's existing
  header/toolbar actions — never a new row of its own. The task's own choice between
  "let the row wrap" and "icon with an `sr-only` label below `sm`": **the latter** —
  `<.header>`'s actions container (`core_components.ex`, not a file this task may edit)
  is `flex-none` inside a `flex` row with no `flex-wrap`, so its content never actually
  wraps onto a second line at any width; it only ever grows the row's intrinsic width,
  which overflows once too many actions are packed in. Keeping this link's own footprint
  to an icon below `sm` (visible text label to a screen reader throughout, via
  `sr-only`/`not-sr-only`) is the one change fully inside this task's own files that
  keeps every screen's header compact at 390px (`NFR-31`) without touching the shared
  header component or any other screen's existing actions.
  """

  use WeddingPlannerWeb, :html

  @doc """
  Renders one `Export CSV` link, id `"export-\#{kind}"`.

  ## Attrs

    * `:kind` (required) — one of `WeddingPlannerWeb.Export.exporters/0`'s string keys
      (`"persons"`, `"events"`, `"headcount"`, `"offers"`, `"invoices"`, `"budget"`,
      `"tasks"`).
    * `:time_zone` (required) — the viewer's browser zone (the host LiveView's
      `@time_zone`), forwarded as `?tz=`.
    * `:label` (default `"Export CSV"`).

  ## Example

      <.export_link kind="persons" time_zone={@time_zone} />
  """
  attr :kind, :string, required: true
  attr :time_zone, :string, required: true
  attr :label, :string, default: "Export CSV"

  def export_link(assigns) do
    ~H"""
    <a
      id={"export-#{@kind}"}
      href={~p"/exports/#{@kind}?#{[tz: @time_zone]}"}
      download
      class="inline-flex min-h-11 items-center justify-center gap-2 rounded-field border border-line-strong bg-transparent px-3 text-sm font-semibold text-ink transition-all duration-150 ease-out hover:bg-surface active:scale-[0.98] active:bg-line focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-accent focus-visible:ring-offset-2 focus-visible:ring-offset-paper sm:px-4"
    >
      <.icon name="hero-arrow-down-tray" class="size-4" />
      <span class="sr-only sm:not-sr-only">{@label}</span>
    </a>
    """
  end
end
