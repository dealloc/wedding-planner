defmodule WeddingPlannerWeb.HomeLive do
  @moduledoc """
  The `/home` dashboard (`docs/modules/home.md` `HOME-01`…`HOME-07`): a read-only summary
  of tasks, money, guests and what needs attention, plus the latest activity. All figures
  come from `WeddingPlannerWeb.HomeOverview` (a pure view-model over one
  `WeddingPlanner.Valuation.Snapshot`); this module only loads, subscribes and renders.

  ## Live updates (`HOME-07`, `XC-01`, `XC-02`)

  Subscribes to every collection topic a card summarises (the budget's set, plus `:task`
  and `:activity_entry`). Any broadcast schedules one reload ~150 ms later; further
  broadcasts inside that window coalesce into it, so a bulk action recomputes the cards
  once. The content changes in place — no highlight, badge or animation (`DR-21`).

  "Today" is the viewer's date (`TodoList.today/1` with `@time_zone`), never
  `Date.utc_today/0` (`DR-44`).
  """
  use WeddingPlannerWeb, :live_view

  import WeddingPlannerWeb.ActivityComponents, only: [activity_entry: 1]

  alias WeddingPlanner.Log.Query, as: LogQuery
  alias WeddingPlanner.Realtime
  alias WeddingPlanner.Repo
  alias WeddingPlanner.Tasks
  alias WeddingPlanner.Tasks.TodoList
  alias WeddingPlanner.Valuation.Snapshot
  alias WeddingPlannerWeb.HomeOverview

  on_mount {WeddingPlannerWeb.Live.TimeZoneHook, :default}

  @topics [
    :settings,
    :category,
    :service,
    :offer,
    :offer_line,
    :override,
    :frozen_service,
    :invoice,
    :invoice_line,
    :event,
    :person,
    :group,
    :invitation,
    :plus_one_opt_out,
    :headcount_preset,
    :task,
    :activity_entry
  ]

  @refresh_after_ms 150
  @activity_limit 5

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket), do: Enum.each(@topics, &Realtime.subscribe/1)

    socket =
      socket
      |> assign(:page_title, "Home")
      |> assign(:refresh_timer, nil)
      |> load()

    {:ok, socket}
  end

  # Any change to what a card summarises: reload once, after a short coalescing window.
  @impl true
  def handle_info({Realtime, _resource, _event}, socket) do
    case socket.assigns.refresh_timer do
      nil ->
        timer = Process.send_after(self(), :refresh, @refresh_after_ms)
        {:noreply, assign(socket, :refresh_timer, timer)}

      _pending ->
        {:noreply, socket}
    end
  end

  def handle_info(:refresh, socket) do
    {:noreply, socket |> assign(:refresh_timer, nil) |> load()}
  end

  defp load(socket) do
    today = TodoList.today(socket.assigns.time_zone)
    overview = HomeOverview.build(Snapshot.load(Repo), today, Tasks.list_tasks_with_graph())

    socket
    |> assign(:overview, overview)
    |> assign(:activity, LogQuery.list(%{limit: @activity_limit}))
  end

  defp task_tone(:bad), do: "text-bad"
  defp task_tone(:warn), do: "text-warn"
  defp task_tone(:neutral), do: "text-ink-soft"

  attr :id, :string, required: true
  attr :title, :string, required: true
  attr :href, :string, required: true
  attr :link_label, :string, default: "Open"
  slot :inner_block, required: true

  defp card(assigns) do
    ~H"""
    <section
      id={@id}
      class="flex flex-col rounded-field border border-line bg-surface-raised p-4 shadow-sm"
    >
      <div class="mb-3 flex items-baseline justify-between gap-3">
        <h2 class="text-sm font-semibold tracking-wide text-ink-soft uppercase">{@title}</h2>
        <.link
          navigate={@href}
          class="text-xs font-medium text-accent transition hover:underline"
        >
          {@link_label} <span aria-hidden="true">→</span>
        </.link>
      </div>
      {render_slot(@inner_block)}
    </section>
    """
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_scope={@current_scope}>
      <div class="space-y-6">
        <div class="flex flex-wrap items-end justify-between gap-4">
          <.header>Wedding Planner</.header>
          <p :if={@overview.countdown} id="home-countdown" class="text-right">
            <span class="block text-3xl font-semibold tracking-tight text-accent">
              {countdown_text(@overview.countdown.days)}
            </span>
            <span class="text-xs text-ink-soft">
              until {@overview.countdown.event} · {@overview.countdown.date}
            </span>
          </p>
          <p :if={is_nil(@overview.countdown)} id="home-countdown" class="text-xs text-ink-faint">
            No upcoming event date set yet
          </p>
        </div>

        <div class="grid grid-cols-1 gap-4 lg:grid-cols-2">
          <.card id="home-tasks" title="Next up" href={~p"/tasks"} link_label="All tasks">
            <p :if={@overview.tasks.items == []} id="home-tasks-empty" class="text-sm text-ink-soft">
              Nothing actionable right now.
            </p>
            <ul :if={@overview.tasks.items != []} class="divide-y divide-line">
              <li
                :for={task <- @overview.tasks.items}
                id={"home-task-#{task.id}"}
                class="flex items-baseline justify-between gap-3 py-2 first:pt-0 last:pb-0"
              >
                <span class="text-sm text-ink">{task.title}</span>
                <span class={["shrink-0 text-xs font-medium", task_tone(task.tone)]}>{task.due}</span>
              </li>
            </ul>
            <p
              :if={@overview.tasks.blocked_count > 0}
              id="home-tasks-blocked"
              class="mt-3 text-xs text-ink-faint"
            >
              {@overview.tasks.blocked_count} more blocked by other tasks
            </p>
          </.card>

          <.card id="home-money" title="Money" href={~p"/budget"} link_label="Budget">
            <p
              :if={@overview.money.status == :missing_presets}
              id="home-money-missing"
              class="text-sm text-ink-soft"
            >
              Assign the Minimum, Likely and Maximum headcount presets to see the forecast.
            </p>

            <div :if={@overview.money.status == :ok}>
              <div
                :if={@overview.money.bar != []}
                id="home-money-bar"
                class="flex h-3 w-full overflow-hidden rounded-chip bg-line"
                role="img"
                aria-label="Paid, still to pay, rest of the forecast and what is left"
              >
                <div
                  :for={part <- @overview.money.bar}
                  class={part.tone}
                  style={"width: #{part.pct}%"}
                  title={"#{part.label}: #{part.amount}"}
                >
                </div>
              </div>
              <dl class="mt-3 grid grid-cols-2 gap-x-4 gap-y-2">
                <div id="home-money-paid">
                  <dt class="flex items-center gap-1.5 text-xs text-ink-soft">
                    <span class="inline-block size-2 rounded-full bg-good"></span> Paid
                  </dt>
                  <dd class="text-sm font-semibold text-ink tabular-nums">{@overview.money.paid}</dd>
                </div>
                <div id="home-money-outstanding">
                  <dt class="flex items-center gap-1.5 text-xs text-ink-soft">
                    <span class="inline-block size-2 rounded-full bg-info"></span> To pay
                  </dt>
                  <dd class="text-sm font-semibold text-ink tabular-nums">
                    {@overview.money.outstanding}
                  </dd>
                </div>
                <div id="home-money-forecast">
                  <dt class="flex items-center gap-1.5 text-xs text-ink-soft">
                    <span class="inline-block size-2 rounded-full bg-warn"></span> Forecast
                  </dt>
                  <dd class="text-sm font-semibold text-ink tabular-nums">
                    {@overview.money.forecast}
                  </dd>
                </div>
                <div id="home-money-available">
                  <dt class="flex items-center gap-1.5 text-xs text-ink-soft">
                    <span class="inline-block size-2 rounded-full bg-line-strong"></span> Available
                  </dt>
                  <dd
                    :if={@overview.money.available == :no_budget}
                    class="text-sm text-ink-faint"
                  >
                    No overall budget set
                  </dd>
                  <dd
                    :if={@overview.money.available != :no_budget}
                    class="text-sm font-semibold text-ink tabular-nums"
                  >
                    {@overview.money.available}
                  </dd>
                </div>
              </dl>
              <p :if={@overview.money.budget} class="mt-3 text-xs text-ink-soft">
                Overall budget {@overview.money.budget}
              </p>
              <p
                :if={@overview.money.over_budget}
                id="home-money-over-budget"
                class="mt-2 rounded-field bg-bad-soft px-3 py-2 text-xs font-medium text-bad"
              >
                Over budget by {@overview.money.over_budget}
              </p>
            </div>

            <ul
              :if={@overview.money.invoices != []}
              id="home-invoices"
              class="mt-3 divide-y divide-line border-t border-line pt-1"
            >
              <li
                :for={invoice <- @overview.money.invoices}
                id={"home-invoice-#{invoice.id}"}
                class="flex items-baseline justify-between gap-3 py-2 text-sm"
              >
                <.link navigate={~p"/invoices/#{invoice.id}"} class="text-ink hover:underline">
                  {invoice.label}
                </.link>
                <span class={[
                  "shrink-0 text-xs tabular-nums",
                  if(invoice.overdue?, do: "font-medium text-bad", else: "text-ink-soft")
                ]}>
                  {invoice.amount} · {if invoice.overdue?, do: "overdue since ", else: "due "}{invoice.due}
                </span>
              </li>
            </ul>
          </.card>

          <.card id="home-guests" title="Guests" href={~p"/headcount"} link_label="Headcount">
            <p
              :if={@overview.guests.status == :missing_presets}
              id="home-guests-missing"
              class="text-sm text-ink-soft"
            >
              Assign the Minimum, Likely and Maximum headcount presets to see the headcount.
            </p>
            <p
              :if={@overview.guests.status == :ok and @overview.guests.events == []}
              id="home-guests-no-events"
              class="text-sm text-ink-soft"
            >
              No events yet.
            </p>
            <table
              :if={@overview.guests.status == :ok and @overview.guests.events != []}
              id="home-headcount"
              class="w-full text-sm"
            >
              <thead>
                <tr class="text-left text-xs text-ink-faint">
                  <th class="pb-1 font-medium">Event</th>
                  <th class="pb-1 text-right font-medium">Min</th>
                  <th class="pb-1 text-right font-medium">Likely</th>
                  <th class="pb-1 text-right font-medium">Max</th>
                </tr>
              </thead>
              <tbody>
                <tr
                  :for={event <- @overview.guests.events}
                  id={"home-event-#{event.id}"}
                  class="border-t border-line"
                >
                  <td class="py-1.5 text-ink">{event.name}</td>
                  <td class="py-1.5 text-right text-ink-soft tabular-nums">{event.min}</td>
                  <td class="py-1.5 text-right font-semibold text-ink tabular-nums">
                    {event.likely}
                  </td>
                  <td class="py-1.5 text-right text-ink-soft tabular-nums">{event.max}</td>
                </tr>
              </tbody>
            </table>
            <div class="mt-4 flex flex-wrap gap-2">
              <.link
                :for={status <- @overview.guests.invitations}
                id={"home-invitations-#{status.key}"}
                navigate={~p"/invitations"}
                class="rounded-chip bg-surface px-3 py-1 text-xs text-ink-soft transition hover:bg-line"
              >
                <span class="font-semibold text-ink tabular-nums">{status.count}</span> {status.label}
              </.link>
            </div>
            <p id="home-people" class="mt-3 text-xs text-ink-faint">
              {@overview.guests.people} {if @overview.guests.people == 1, do: "person", else: "people"}<span :if={
                @overview.guests.possible_plus_ones > 0
              }> · {@overview.guests.possible_plus_ones} possible +1{if @overview.guests.possible_plus_ones ==
                                                                          1, do: "", else: "s"}</span>
            </p>
          </.card>

          <.card
            id="home-attention"
            title="Needs attention"
            href={~p"/categories"}
            link_label="Categories"
          >
            <p
              :if={@overview.attention.items == []}
              id="home-attention-clear"
              class="text-sm text-ink-soft"
            >
              Nothing needs a decision right now.
            </p>
            <ul :if={@overview.attention.items != []} class="space-y-2">
              <li
                :for={item <- @overview.attention.items}
                id={"home-attention-#{item.id}"}
                class="flex items-start gap-2 text-sm text-ink"
              >
                <.icon name="hero-exclamation-triangle" class="mt-0.5 size-4 shrink-0 text-warn" />
                <.link navigate={item.path} class="hover:underline">{item.text}</.link>
              </li>
            </ul>
            <p :if={@overview.attention.more > 0} class="mt-2 text-xs text-ink-faint">
              and {@overview.attention.more} more
            </p>
          </.card>
        </div>

        <.card id="home-activity" title="Recent activity" href={~p"/activity"} link_label="Full log">
          <p :if={@activity == []} class="text-sm text-ink-soft">No activity yet.</p>
          <ul :if={@activity != []} class="divide-y divide-line">
            <li :for={entry <- @activity} class="py-2 first:pt-0 last:pb-0">
              <.activity_entry id={"home-activity-#{entry.id}"} entry={entry} time_zone={@time_zone} />
            </li>
          </ul>
        </.card>
      </div>
    </Layouts.app>
    """
  end

  defp countdown_text(0), do: "Today"
  defp countdown_text(1), do: "1 day"
  defp countdown_text(days), do: "#{days} days"
end
