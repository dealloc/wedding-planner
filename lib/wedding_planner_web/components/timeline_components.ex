defmodule WeddingPlannerWeb.TimelineComponents do
  @moduledoc """
  Rendering for `/timeline` (task 77; `docs/modules/tasks-and-timeline.md` **TSK-21**,
  **TSK-22**, **TSK-23**; `.claude/plans/roadmap.md` **DR-68**). Every placement decision
  (lanes, rows, arrows, tones, milestones, ticks, the phone list) is made by
  `WeddingPlanner.Tasks.Timeline.build/2` — this module only **positions and styles**
  that view model. `WeddingPlannerWeb.Live.TimelineLive` owns the socket/selection state;
  these are plain function components over its `%Timeline{}` assign.

  ## One shared y per row (`DR-68`'s v3 arrow fix)

  `row_y/1` is the **single** place a row's dot-centre pixel offset is computed. Every
  dot, its label position and every SVG arrow endpoint call it — never a second, ad hoc
  offset — which is exactly the bug the locked design's v3 revision fixed (arrows drawn
  off-centre from their dots because the two used different constants). Each dot also
  carries `data-y` with that same value, so a test can assert an arrow's `y1`/`y2`
  literally equals the endpoint dot's `data-y` rather than trusting the two formulas stay
  in sync by eye.

  ## Percent x, integer arithmetic

  `WeddingPlanner.Tasks.Timeline`'s `x` is an integer `0..10_000` (hundredths of a percent
  of the axis width, `NFR-12`'s no-floats spirit). `x_pct/1` is the one place that becomes
  a CSS `left`/SVG `x` string (`"12.34%"`), by plain integer `div`/`rem` — never a float
  division.

  ## Arrows are per-lane SVG overlays

  One absolutely positioned `<svg>` per lane (never one global overlay) — arrows can only
  connect two points in the *same* lane (`Timeline`'s own invariant: "arrows between lanes
  cannot occur, a chain is one lane"), so each lane's overlay only ever needs its own
  arrows, addressed by row-local pixel y and lane-relative percent x.

  ## Task labels: capped width + an inset plot area, not edge anchoring

  Two rendering-only fixes (review feedback, not a `docs/`/DR-68 change): a task point's
  whole label box (title **and** its "waits on" caption — both are normal-flow children
  of it, so both wrap within it) gets a CSS `max-width` capped at `label_gap/0` — the
  same `min_gap` `WeddingPlannerWeb.Live.TimelineLive` now passes explicitly to
  `Timeline.build/2` — so two labels whose dots the engine has already promised are at
  least `label_gap/0` apart can never touch even at their widest (`label_max_width/0`).
  The `max-width` lives **only** on that outer box, deliberately — repeating it as a
  percentage on a normal-flow child would resolve against the *child's own* (already
  shrunk) containing block and compound the shrink, wrapping every word onto its own
  line. Second, the whole plot area (dots, ticks, arrows, the today marker, milestone
  lines) is inset horizontally by half a label's max width (`plot_inset/0`) inside the
  axis container, so a label centred on a dot at `x = 0` or `x = 10_000` has room to
  render instead of half of it having nowhere to go. Milestone labels keep the earlier
  edge-anchoring fix instead (`edge_anchor_classes/1`) — they sit in their own rows now
  (see below) and centring them wasn't the reported problem.

  ## Selection dims tasks only (`DR-68`)

  Selecting a task highlights `WeddingPlanner.Tasks.Timeline.chain/2` and dims every other
  **task** point; milestones, the today marker and the side lane are never dimmed — they
  are not part of any dependency chain. Selecting a side-lane task (not itself placed) has
  no highlighting or dimming effect on the axis at all (the task file's "no chain on the
  axis" case) — the caller passes an empty `chain` for that case, so every point simply
  renders `data-in-chain="false"` with no dimming class applied.
  """
  use WeddingPlannerWeb, :html

  import WeddingPlannerWeb.TaskComponents, only: [deadline_text: 1]

  alias WeddingPlannerWeb.Format

  @row_height 88
  @dot_offset 14
  @lane_bottom_pad 64
  @milestone_row_height 64
  @milestone_min_gap 900
  @ticks_height 32
  @edge_left 1_000
  @edge_right 9_000

  # Coordinator feedback: two task labels in the same lane row could still visually
  # collide even though the engine's default `min_gap` (1_200, 12%) kept their *dots*
  # apart, because a label can be wider in pixels than 12% of a wide viewport. This is
  # the single source both `WeddingPlannerWeb.Live.TimelineLive` (which passes it to
  # `Timeline.build/2`'s `min_gap` option, so the engine's own row placement guarantees
  # this much x-distance between row-mates) and `label_max_width/0` (which caps a label
  # at this same fraction, minus a small margin, so it wraps instead of reaching that
  # far) read — the two literally cannot drift since they're the same number.
  @label_gap 1_500

  @doc """
  The x-gap (in the engine's `0..10_000` units) `WeddingPlannerWeb.Live.TimelineLive`
  passes to `Timeline.build/2`'s `min_gap` option, and the basis for
  `label_max_width/0` — see the moduledoc-adjacent comment above `@label_gap`.
  """
  @spec label_gap() :: pos_integer()
  def label_gap, do: @label_gap

  @doc """
  A task point's label box `max-width` (its title and "waits on" caption both wrap
  inside it, being normal-flow children — see the moduledoc): the same `label_gap/0`
  fraction of the plot width, less a small margin, so two labels whose dots are
  `label_gap/0` apart (the engine's own guarantee once `TimelineLive` passes it as
  `min_gap`) can never touch even at their widest. Built from `x_pct/1` — the same
  integer `div`/`rem`, no float division. Applied to that one box only — see the
  moduledoc for why repeating it on a child would compound the shrink.
  """
  @spec label_max_width() :: String.t()
  def label_max_width, do: "calc(#{x_pct(@label_gap)} - 0.5rem)"

  @doc """
  Half a label's max width — applied as `margin-left`/`margin-right` on the plot area
  (dots, ticks, arrows, the today marker and milestone lines all position inside it), so
  a label centred on a dot at the very start or end of the range still has room to
  render, instead of the label's off-container half being clipped (the bug edge-
  anchoring used to work around for task labels; milestones still use that,
  `edge_anchor_classes/1`). Margin, not `left`/`right` on an absolutely positioned box:
  the plot area must stay in normal flow so its own content (lanes, ticks) still
  determines its height — an absolutely positioned plot area has nothing left in flow to
  give the axis container a height at all.
  """
  @spec plot_inset() :: String.t()
  def plot_inset, do: "calc(#{label_max_width()} / 2)"

  # -- pixel/percent helpers (single source, see moduledoc) ----------------------------

  @doc """
  The pixel y of a row's dot centre, relative to its lane's own top — the **only** place
  this offset is computed (see the moduledoc). Every dot, its arrow endpoints and its
  `data-y` attribute all call this, so they cannot drift apart.
  """
  @spec row_y(non_neg_integer()) :: non_neg_integer()
  def row_y(row) when is_integer(row) and row >= 0, do: row * @row_height + @dot_offset

  @doc """
  Renders a `Timeline`'s `x` (an integer `0..10_000`, hundredths of a percent) as a CSS
  percentage string (`"12.34%"`) by integer `div`/`rem` — never a float division
  (`NFR-12`'s spirit).
  """
  @spec x_pct(0..10_000) :: String.t()
  def x_pct(x) when is_integer(x) and x >= 0 and x <= 10_000 do
    "#{div(x, 100)}.#{pad2(rem(x, 100))}%"
  end

  defp pad2(n) when n < 10, do: "0#{n}"
  defp pad2(n), do: "#{n}"

  defp lane_height(lane), do: lane.row_count * @row_height + @lane_bottom_pad

  # `@`-prefixed module attributes are not visible inside a `~H` template (there, `@foo`
  # is always an assigns lookup) — these small wrappers are what the axis markup below
  # calls instead, so the constants still live in exactly one place (the moduledoc's
  # "one shared y per row" point).
  defp row_height, do: @row_height
  defp dot_offset, do: @dot_offset
  defp milestone_row_height, do: @milestone_row_height
  defp ticks_height, do: @ticks_height

  # -- milestone label rows (coordinator feedback: same-date/near-coincident milestones
  # were overlapping into unreadable text) ---------------------------------------------
  #
  # The engine (`Timeline.build/2`) gives every milestone an `x` but no row — grouping
  # is purely a rendering/label-collision concern, so it lives here, mirroring the
  # engine's own lane-row first-fit (`Timeline.lane/3`'s `first_fit/4`) but independent
  # of it: milestones sorted by `x`, greedily placed in the first row whose last member
  # is `@milestone_min_gap` (9%) or farther away, else a new row. Two milestones on the
  # same date always land >= `@milestone_min_gap` apart in x-terms (gap 0), so they
  # always separate into different rows — "the same date at minimum", per the brief, and
  # anything closer than ~9% of the axis width besides. Each milestone keeps its own
  # dashed line (anchored under its own row, not a shared one) and its own link/id/icon —
  # grouping only ever changes vertical position, never identity.
  defp milestone_rows(milestones) do
    milestones
    |> Enum.sort_by(& &1.x)
    |> Enum.map_reduce([], fn milestone, row_ends ->
      row = milestone_first_fit(row_ends, milestone.x, 0)

      row_ends =
        if row == length(row_ends),
          do: row_ends ++ [milestone.x],
          else: List.replace_at(row_ends, row, milestone.x)

      {{milestone, row}, row_ends}
    end)
    |> elem(0)
  end

  defp milestone_first_fit([], _x, row), do: row

  defp milestone_first_fit([last_x | rest], x, row) do
    if x - last_x >= @milestone_min_gap,
      do: row,
      else: milestone_first_fit(rest, x, row + 1)
  end

  # The header area's total height: one `@milestone_row_height` per row actually used
  # (at least one, even with zero milestones, so the axis keeps its usual top margin).
  defp header_height(milestone_rows) do
    row_count = milestone_rows |> Enum.map(fn {_milestone, row} -> row end) |> max_row()
    row_count * @milestone_row_height
  end

  defp max_row([]), do: 1
  defp max_row(rows), do: Enum.max(rows) + 1

  # A milestone's own dashed line starts just under its own label row (not the header's
  # overall bottom), so it reads as "this line belongs to this label" even when other
  # milestones stack above or below it.
  defp milestone_line_top(row), do: (row + 1) * @milestone_row_height - 20

  # -- edge anchoring: milestones and the today marker only ----------------------------
  #
  # Task labels no longer use this (see the moduledoc's "Task labels" section) — they're
  # always centred now, protected from clipping by `plot_inset/0` instead. Milestone
  # labels (their own rows now, see `milestone_rows/1`) and the today tag keep it: below
  # 10% a label anchors to its **start** (grows rightward from the dot, `items-start`/
  # `text-left`, no translate); above 90% it anchors to its **end** (grows leftward,
  # `items-end`/`text-right`, `-translate-x-full`); in between it stays centred. Either
  # way the dot/line itself — the first flex item in a `flex-col`, so `items-*` controls
  # its horizontal position too — lands exactly on `x`.
  defp edge_anchor_classes(x) when x < @edge_left, do: ["items-start", "text-left"]

  defp edge_anchor_classes(x) when x > @edge_right do
    ["items-end", "text-right", "-translate-x-full"]
  end

  defp edge_anchor_classes(_x), do: ["items-center", "text-center", "-translate-x-1/2"]

  defp tick_key(%Date{} = date), do: Calendar.strftime(date, "%Y-%m")

  defp quoted_titles(tasks), do: Enum.map_join(tasks, ", ", &"'#{&1.title}'")

  # -- tone captions ---------------------------------------------------------------------
  #
  # Axis captions are deliberately sparse (done/pure-overdue/pure-actionable show no
  # caption at all — colour already carries the tone); the phone list shows one for every
  # row (TSK-22 carries "the same tones and captions" but has no colour to lean on).

  defp axis_caption(%{tone: :overdue, blocked?: true}), do: "Overdue · Blocked"
  defp axis_caption(%{tone: :overdue}), do: nil
  defp axis_caption(%{tone: :blocked} = point), do: "waits on " <> quoted_titles(point.waits_on)
  defp axis_caption(%{tone: :actionable, in_progress?: true}), do: "In progress"
  defp axis_caption(%{tone: :actionable}), do: nil
  defp axis_caption(%{tone: :done}), do: nil

  defp list_task_caption(%{tone: :done}), do: "Done"
  defp list_task_caption(%{tone: :overdue, blocked?: true}), do: "Overdue · Blocked"
  defp list_task_caption(%{tone: :overdue}), do: "Overdue"

  defp list_task_caption(%{tone: :blocked} = point) do
    "Blocked · waiting on " <> quoted_titles(point.waits_on)
  end

  defp list_task_caption(%{tone: :actionable, in_progress?: true}), do: "In progress"
  defp list_task_caption(%{tone: :actionable}), do: "Actionable"

  @doc false
  # Shared by the panel and (indirectly) nowhere else — the panel's own "Effective
  # deadline dd/mm/yyyy · <tag>" line, where <tag> is nil for the plain actionable case
  # (no " · " suffix at all then).
  def tone_label(%{tone: :done}), do: "Done"
  def tone_label(%{tone: :overdue, blocked?: true}), do: "Overdue · Blocked"
  def tone_label(%{tone: :overdue}), do: "Overdue"
  def tone_label(%{tone: :blocked}), do: "Blocked"
  def tone_label(%{tone: :actionable, in_progress?: true}), do: "In progress"
  def tone_label(%{tone: :actionable}), do: nil

  defp tone_dot_class(:done), do: "bg-good"
  defp tone_dot_class(:overdue), do: "bg-bad"
  defp tone_dot_class(:blocked), do: "bg-warn"
  defp tone_dot_class(:actionable), do: "bg-ink"

  defp tone_text_class(:done), do: "text-good"
  defp tone_text_class(:overdue), do: "text-bad"
  defp tone_text_class(:blocked), do: "text-warn"
  defp tone_text_class(:actionable), do: "text-ink"

  defp lane_label(%{kind: :chain}), do: "Dependency chain"
  defp lane_label(%{kind: :independent}), do: "No dependencies"

  # -- selection ---------------------------------------------------------------------

  defp in_chain?(chain, task_id), do: MapSet.member?(chain, task_id)

  defp dim?(chain, selected, task_id) do
    selected != nil and MapSet.size(chain) > 0 and not MapSet.member?(chain, task_id)
  end

  defp lane_arrows(arrows, lane) do
    ids = MapSet.new(lane.points, & &1.task.id)
    Enum.filter(arrows, &(MapSet.member?(ids, &1.from) and MapSet.member?(ids, &1.to)))
  end

  defp point_by_id(lane, id), do: Enum.find(lane.points, &(&1.task.id == id))

  # -- legend --------------------------------------------------------------------------

  attr :id, :string, required: true

  def timeline_legend(assigns) do
    ~H"""
    <div id={@id} class="flex flex-wrap items-center gap-4 text-sm text-ink-soft">
      <span class="flex items-center gap-1.5">
        <span class="size-2.5 rounded-full bg-ink"></span> Actionable
      </span>
      <span class="flex items-center gap-1.5">
        <span class="size-2.5 rounded-full bg-warn"></span> Blocked
      </span>
      <span class="flex items-center gap-1.5">
        <span class="size-2.5 rounded-full bg-bad"></span> Overdue
      </span>
      <span class="flex items-center gap-1.5">
        <span class="size-2.5 rounded-full bg-good"></span> Done
      </span>
    </div>
    """
  end

  # -- axis ------------------------------------------------------------------------------

  attr :id, :string, required: true
  attr :timeline, :map, required: true
  attr :selected, :any, default: nil
  attr :chain, :any, required: true

  def timeline_axis(assigns) do
    assigns = assign(assigns, :milestone_rows, milestone_rows(assigns.timeline.milestones))

    ~H"""
    <div id={@id} class="relative min-w-[960px]">
      <div
        id={"#{@id}-plot"}
        class="relative"
        style={"margin-left: #{plot_inset()}; margin-right: #{plot_inset()}"}
      >
        <div
          :for={{milestone, row} <- @milestone_rows}
          class="absolute inset-y-0"
          style={"left: #{x_pct(milestone.x)}"}
          data-overdue={to_string(milestone.overdue?)}
        >
          <div
            class={[
              "absolute bottom-0 left-0 border-l border-dashed",
              milestone.overdue? && "border-bad",
              not milestone.overdue? && "border-line-strong"
            ]}
            style={"top: #{milestone_line_top(row)}px"}
          >
          </div>
          <.link
            navigate={milestone_href(milestone)}
            id={"timeline-milestone-#{milestone.kind}-#{milestone.id}"}
            class={
              [
                "absolute flex w-32 flex-col text-xs",
                milestone.overdue? && "text-bad",
                not milestone.overdue? && "text-ink-soft"
              ] ++ edge_anchor_classes(milestone.x)
            }
            style={"top: #{row * milestone_row_height()}px"}
          >
            <.icon
              name={if milestone.kind == :event, do: "hero-flag", else: "hero-banknotes"}
              class="size-4"
            />
            <span class="mt-1 font-medium">{milestone.label}</span>
            <span :if={milestone.kind == :invoice} class="tabular-nums">
              {Format.money(milestone.amount)}
            </span>
          </.link>
        </div>

        <div
          :if={@timeline.today.x}
          id="timeline-today"
          class="absolute inset-y-0"
          style={"left: #{x_pct(@timeline.today.x)}"}
        >
          <div class="absolute inset-y-0 left-0 w-px bg-accent"></div>
          <span class={
            ["absolute top-0 rounded-chip bg-accent px-2 py-0.5 text-xs font-semibold text-white"] ++
              edge_anchor_classes(@timeline.today.x)
          }>
            Today
          </span>
        </div>

        <div style={"height: #{header_height(@milestone_rows)}px"}></div>

        <div
          :for={{lane, index} <- Enum.with_index(@timeline.lanes)}
          id={"timeline-lane-#{index}"}
          class="border-t border-line pt-2"
        >
          <p class="text-xs font-semibold tracking-wide text-ink-faint uppercase">
            {lane_label(lane)}
          </p>

          <div class="relative" style={"height: #{lane_height(lane)}px"}>
            <svg class="pointer-events-none absolute inset-0" width="100%" height="100%">
              <defs>
                <marker
                  id={"timeline-arrowhead-#{index}"}
                  markerWidth="8"
                  markerHeight="8"
                  refX="7"
                  refY="4"
                  orient="auto"
                >
                  <path d="M0,0 L8,4 L0,8 Z" class="fill-accent" />
                </marker>
              </defs>
              <line
                :for={arrow <- lane_arrows(@timeline.arrows, lane)}
                id={"timeline-arrow-#{arrow.from}-#{arrow.to}"}
                x1={x_pct(point_by_id(lane, arrow.from).x)}
                y1={row_y(point_by_id(lane, arrow.from).row)}
                x2={x_pct(point_by_id(lane, arrow.to).x)}
                y2={row_y(point_by_id(lane, arrow.to).row)}
                data-y1={row_y(point_by_id(lane, arrow.from).row)}
                data-y2={row_y(point_by_id(lane, arrow.to).row)}
                class="stroke-accent"
                stroke-width="1.5"
                marker-end={"url(##{"timeline-arrowhead-#{index}"})"}
              />
            </svg>

            <.link
              :for={point <- lane.points}
              patch={~p"/timeline?task=#{point.task.id}"}
              id={"timeline-point-#{point.task.id}"}
              data-tone={point.tone}
              data-in-chain={to_string(in_chain?(@chain, point.task.id))}
              class={[
                "absolute flex -translate-x-1/2 flex-col items-center text-center transition-opacity",
                dim?(@chain, @selected, point.task.id) && "opacity-30"
              ]}
              style={"left: #{x_pct(point.x)}; top: #{point.row * row_height()}px; max-width: #{label_max_width()}"}
            >
              <span
                data-y={row_y(point.row)}
                class={[
                  "size-2.5 rounded-full ring-2 ring-offset-2 ring-offset-paper",
                  tone_dot_class(point.tone),
                  if(@selected == point.task.id, do: "ring-accent", else: "ring-transparent")
                ]}
                style={"margin-top: #{dot_offset() - 5}px"}
              ></span>
              <span class={["mt-1.5 text-xs font-medium", tone_text_class(point.tone)]}>
                {point.task.title}
              </span>
              <span :if={axis_caption(point)} class="text-xs text-ink-faint">
                {axis_caption(point)}
              </span>
            </.link>
          </div>
        </div>

        <div class="relative border-t border-line" style={"height: #{ticks_height()}px"}>
          <span
            :for={tick <- @timeline.ticks}
            id={"timeline-tick-#{tick_key(tick.date)}"}
            class="absolute top-1.5 -translate-x-1/2 text-xs text-ink-faint"
            style={"left: #{x_pct(tick.x)}"}
          >
            {Format.month(tick.date)}
          </span>
        </div>
      </div>
    </div>
    """
  end

  defp milestone_href(%{kind: :event, id: id}), do: ~p"/events/#{id}/edit"
  defp milestone_href(%{kind: :invoice, id: id}), do: ~p"/invoices/#{id}"

  # -- side lane -------------------------------------------------------------------------

  attr :id, :string, required: true
  attr :side_lane, :list, required: true
  attr :selected, :any, default: nil

  def timeline_side_lane(assigns) do
    ~H"""
    <div id={@id} class="space-y-2">
      <p class="text-xs font-semibold tracking-wide text-ink-faint uppercase">
        No effective deadline
      </p>
      <div class="flex flex-wrap gap-2">
        <.link
          :for={item <- @side_lane}
          patch={~p"/timeline?task=#{item.task.id}"}
          id={"timeline-side-#{item.task.id}"}
          data-tone={item.tone}
          class={[
            "rounded-chip border px-3 py-1.5 text-sm transition",
            @selected == item.task.id && "border-accent bg-accent-soft",
            @selected != item.task.id && "border-line-strong text-ink-soft hover:bg-surface"
          ]}
        >
          {side_chip_text(item)}
        </.link>
      </div>
    </div>
    """
  end

  defp side_chip_text(%{task: task, resolved: :none}), do: task.title

  defp side_chip_text(%{task: task, resolved: {:unresolved, _event}}) do
    "#{task.title} — #{deadline_text(task)}"
  end

  # -- reading panel ---------------------------------------------------------------------

  attr :id, :string, required: true
  attr :panel, :map, required: true

  def timeline_panel(assigns) do
    ~H"""
    <div id={@id} class="rounded-field border border-line bg-surface-raised p-4">
      <div class="flex items-start justify-between gap-4">
        <div>
          <p class="font-semibold text-ink">{@panel.task.title}</p>
          <p class="text-sm text-ink-soft">{@panel.deadline_line}</p>
        </div>
        <div class="flex shrink-0 items-center gap-3 text-sm">
          <.link
            navigate={~p"/tasks?open=#{@panel.task.id}"}
            id="timeline-panel-open-in-tasks"
            class="font-medium text-accent hover:underline"
          >
            Open in Tasks
          </.link>
          <.link
            patch={~p"/timeline"}
            id="timeline-panel-clear"
            class="font-medium text-ink-soft hover:underline"
          >
            Clear
          </.link>
        </div>
      </div>

      <div class="mt-4 grid gap-4 sm:grid-cols-2">
        <div>
          <p class="text-xs font-semibold tracking-wide text-ink-faint uppercase">Waits on</p>
          <p :if={@panel.waits_on == []} class="text-sm text-ink-faint">Nothing</p>
          <p :for={task <- @panel.waits_on} class="text-sm">
            <.link patch={~p"/timeline?task=#{task.id}"} class="text-accent hover:underline">
              {task.title}
            </.link>
          </p>
        </div>
        <div>
          <p class="text-xs font-semibold tracking-wide text-ink-faint uppercase">
            Waiting on this
          </p>
          <p :if={@panel.waiting_on_this == []} class="text-sm text-ink-faint">Nothing</p>
          <p :for={task <- @panel.waiting_on_this} class="text-sm">
            <.link patch={~p"/timeline?task=#{task.id}"} class="text-accent hover:underline">
              {task.title}
            </.link>
          </p>
        </div>
      </div>
    </div>
    """
  end

  # -- phone list (TSK-22) ---------------------------------------------------------------

  attr :id, :string, required: true
  attr :list, :list, required: true
  attr :selected, :any, default: nil

  def timeline_list(assigns) do
    ~H"""
    <ul id={@id} class="divide-y divide-line rounded-field border border-line">
      <li :for={entry <- @list} class="flex items-center gap-3 px-4 py-3">
        <.link
          patch={list_item_patch(entry)}
          navigate={list_item_navigate(entry)}
          id={list_item_id(entry)}
          class="flex flex-1 items-center gap-3 min-w-0"
        >
          <span
            data-tone={list_item_tone(entry)}
            class={["size-2.5 shrink-0 rounded-full", list_item_dot_class(entry)]}
          ></span>
          <span class="min-w-0 flex-1">
            <span class="block truncate text-sm font-medium text-ink">
              {list_item_title(entry)}
            </span>
            <span class="block text-xs text-ink-faint">{list_item_caption(entry)}</span>
          </span>
          <span :if={entry.date} class="shrink-0 text-xs tabular-nums text-ink-soft">
            {Format.date(entry.date)}
          </span>
        </.link>
      </li>
    </ul>
    """
  end

  defp list_item_id(%{kind: :task, item: point}), do: "timeline-list-task-#{point.task.id}"
  defp list_item_id(%{kind: :event, item: milestone}), do: "timeline-list-event-#{milestone.id}"

  defp list_item_id(%{kind: :invoice, item: milestone}) do
    "timeline-list-invoice-#{milestone.id}"
  end

  defp list_item_id(%{kind: :side, item: side}), do: "timeline-list-side-#{side.task.id}"

  # `patch` (same LiveView, `?task=` selection) for task/side rows; `navigate` (a
  # different LiveView entirely) for event/invoice milestone rows — mixing these up is
  # exactly the kind of bug `<.link patch={...}>` to a foreign route would silently
  # produce (a same-LiveView param diff that never actually navigates).
  defp list_item_patch(%{kind: :task, item: point}), do: ~p"/timeline?task=#{point.task.id}"
  defp list_item_patch(%{kind: :side, item: side}), do: ~p"/timeline?task=#{side.task.id}"
  defp list_item_patch(%{kind: kind}) when kind in [:event, :invoice], do: nil

  defp list_item_navigate(%{kind: kind} = entry) when kind in [:event, :invoice] do
    milestone_href(entry.item)
  end

  defp list_item_navigate(%{kind: kind}) when kind in [:task, :side], do: nil

  defp list_item_title(%{kind: :task, item: point}), do: point.task.title
  defp list_item_title(%{kind: :side, item: side}), do: side.task.title
  defp list_item_title(%{item: milestone}), do: milestone.label

  defp list_item_tone(%{kind: :task, item: point}), do: point.tone
  defp list_item_tone(%{kind: :side, item: side}), do: side.tone
  defp list_item_tone(%{kind: kind}) when kind in [:event, :invoice], do: :milestone

  defp list_item_dot_class(%{kind: :task, item: point}), do: tone_dot_class(point.tone)
  defp list_item_dot_class(%{kind: :side, item: side}), do: tone_dot_class(side.tone)
  defp list_item_dot_class(%{kind: :event}), do: "bg-ink-soft"

  defp list_item_dot_class(%{kind: :invoice, item: milestone}) do
    if milestone.overdue?, do: "bg-bad", else: "bg-ink-soft"
  end

  defp list_item_caption(%{kind: :task, item: point}), do: list_task_caption(point)
  defp list_item_caption(%{kind: :event}), do: "Milestone · event date"

  defp list_item_caption(%{kind: :invoice, item: milestone}) do
    "Milestone · invoice due #{Format.money(milestone.amount)}"
  end

  defp list_item_caption(%{kind: :side, item: %{resolved: :none}}), do: "No deadline"

  defp list_item_caption(%{kind: :side, item: %{resolved: {:unresolved, _}} = side}) do
    deadline_text(side.task)
  end
end
