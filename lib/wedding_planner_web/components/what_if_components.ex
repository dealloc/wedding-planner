defmodule WeddingPlannerWeb.Components.WhatIfComponents do
  @moduledoc """
  The display idioms for `/what-if` (task 89; `DR-82`): the picker (`picker/1`), one
  draft-editor card per selected person (`person_card/1`), the recomputed preview
  (`headcount_rows/1`, `category_rows/1`, `overall/1`) and the Apply confirmation panel
  (`apply_confirm/1`).

  All of them render `WeddingPlannerWeb.WhatIfView.build/5`'s output — no computation
  happens here, only display, exactly like `WeddingPlannerWeb.Components.BudgetComponents`.
  Every three-role figure goes through that module's own `role_values/1`, reused
  **unmodified** (`DR-71`) — nothing here re-derives a business rule.

  ## Loading (orchestrator amendment, loading state & latency)

  `loading_targets/0` is this screen's own equivalent of
  `WeddingPlannerWeb.Components.BudgetComponents.loading_targets/0`: the one CSS
  selector every recomputing region shares, passed to every `JS.push/2`'s `:loading`
  option on this page (the preset form, every cell select's own form, "Set for
  everyone here", and every `role_values/1` button) so the LiveView JS client dims them
  **instantly**, client-side, at click/change time — before `@recomputing` (the
  server-side signal covering the async rebuild itself) can reach the page.
  """

  use WeddingPlannerWeb, :html

  import WeddingPlannerWeb.Components.BudgetComponents, only: [role_values: 1]

  @doc """
  The CSS selector every recomputing region on `/what-if` shares (see the moduledoc):
  the whole preview (`#what-if-preview`) and its client-side "Updating…" twin
  (`#what-if-updating`).
  """
  @spec loading_targets() :: String.t()
  def loading_targets, do: "#what-if-preview, #what-if-updating"

  # -- the picker (INVT-04's B-list) -----------------------------------------------------------

  @doc """
  The people/group picker (`INVT-04`): a name search, "Not counted under &lt;likely
  preset&gt;" and "Want tier maybe" filter chips, results with an Add button, and "Add
  a group". Collapsible (`<details>`), open when nobody is selected yet (`DR-82`).

  `:results` is `WeddingPlannerWeb.WhatIfView.build/5`'s `:picker_candidates`, already
  narrowed by the caller's search/filter assigns (+1s already excluded by the view
  model) **and capped** (orchestrator amendment, layout compaction: 52 demo people as
  tall cards pushed the draft and preview far down the page) — `:total_matches` is the
  pre-cap count, so a truncated list says so rather than silently hiding the rest.
  `:groups` is `:groups`.
  """
  attr :id, :string, default: "what-if-picker"
  attr :open?, :boolean, required: true
  attr :likely_preset_name, :string, required: true
  attr :query, :string, required: true
  attr :not_counted?, :boolean, required: true
  attr :maybe?, :boolean, required: true
  attr :results, :list, required: true
  attr :total_matches, :integer, required: true
  attr :groups, :list, required: true

  def picker(assigns) do
    ~H"""
    <details id={@id} open={@open?} class="rounded-field border border-line bg-surface-raised">
      <summary class="cursor-pointer list-none select-none px-4 py-3 text-sm font-medium text-ink-soft transition hover:text-ink focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-accent">
        Pick people
      </summary>

      <div class="space-y-3 border-t border-line px-4 py-4">
        <form
          id="what-if-search"
          class="contents"
          phx-change={JS.push("search", loading: loading_targets())}
        >
          <.input
            type="text"
            name="q"
            id="what-if-search-input"
            label="Search by name"
            value={@query}
            placeholder="Name contains…"
          />
        </form>

        <div class="flex flex-wrap gap-2">
          <button
            type="button"
            id="what-if-filter-not-counted"
            phx-click={JS.push("toggle_filter", value: %{"filter" => "not_counted"})}
            aria-pressed={to_string(@not_counted?)}
            class={[
              "rounded-chip border px-3 py-1.5 text-sm font-medium transition",
              if(@not_counted?,
                do: "border-accent bg-accent-soft text-accent",
                else: "border-line-strong bg-surface text-ink-soft hover:bg-surface-raised"
              )
            ]}
          >
            Not counted under {@likely_preset_name}
          </button>
          <button
            type="button"
            id="what-if-filter-maybe"
            phx-click={JS.push("toggle_filter", value: %{"filter" => "maybe"})}
            aria-pressed={to_string(@maybe?)}
            class={[
              "rounded-chip border px-3 py-1.5 text-sm font-medium transition",
              if(@maybe?,
                do: "border-accent bg-accent-soft text-accent",
                else: "border-line-strong bg-surface text-ink-soft hover:bg-surface-raised"
              )
            ]}
          >
            Want tier maybe
          </button>
        </div>

        <p :if={@results == []} id="what-if-no-results" class="text-sm text-ink-faint">
          No one matches — try a different search or clear the filters.
        </p>

        <%!-- Compacted (orchestrator amendment, layout compaction): a single-line row per
             candidate, no per-row border box, capped to roughly 8 rows' height with a
             scroll for the rest — 52 demo people as tall bordered cards used to push the
             draft and preview far down the page. `relative` on the scroll container per
             plan §2's own trap about `overflow-x-auto`/`overflow-y-auto` boxes. --%>
        <div
          :if={@results != []}
          class="relative max-h-64 overflow-y-auto rounded-field border border-line"
        >
          <ul class="divide-y divide-line">
            <li
              :for={result <- @results}
              id={"what-if-result-#{result.id}"}
              class="flex items-center justify-between gap-2 bg-surface px-3 py-2"
            >
              <span class="min-w-0 truncate text-sm">
                <.link
                  navigate={~p"/people/#{result.id}"}
                  class="font-medium text-ink hover:underline"
                >
                  {result.name}
                </.link>
                <span class="text-xs text-ink-faint"> — {result.counted_caption}</span>
              </span>
              <button
                type="button"
                id={"what-if-result-#{result.id}-add"}
                phx-click={JS.push("picker_add", value: %{"id" => result.id})}
                class="shrink-0 rounded-chip border border-line-strong bg-surface-raised px-2.5 py-1 text-xs font-medium text-ink transition hover:bg-line/40"
              >
                Add
              </button>
            </li>
          </ul>
        </div>

        <p
          :if={@total_matches > length(@results)}
          id="what-if-results-truncated"
          class="text-xs text-ink-faint"
        >
          Showing {length(@results)} of {@total_matches} — narrow your search to see more.
        </p>

        <form id="what-if-add-group" class="contents" phx-submit="picker_add_group">
          <div class="flex flex-wrap items-end gap-2">
            <.input
              type="select"
              name="group_id"
              id="what-if-add-group-select"
              label="Add a group"
              prompt="Pick a group"
              value={nil}
              options={Enum.map(@groups, &{&1.name, &1.id})}
            />
            <.button variant="secondary" id="what-if-add-group-submit">Add</.button>
          </div>
        </form>
      </div>
    </details>
    """
  end

  # -- the draft editor's person cards (DR-80: +1s follow their host, PER-13) ------------------

  @doc """
  One selected person's draft-editor card: their name (linking to `/people/:id`), a
  Remove control, their +1s listed read-only ("follows host"), and one select per event
  (`person.cells`), each in its own `<form class="contents">` (the UI trap: a bare
  `<select phx-change>` is silently dropped, plan §2).
  """
  attr :person, :map, required: true

  def person_card(assigns) do
    ~H"""
    <div
      id={"what-if-person-#{@person.id}"}
      class="rounded-field border border-line bg-surface-raised p-4"
    >
      <div class="flex flex-wrap items-center justify-between gap-2">
        <.link navigate={~p"/people/#{@person.id}"} class="font-semibold text-ink hover:underline">
          {@person.name}
        </.link>
        <button
          type="button"
          id={"what-if-person-#{@person.id}-remove"}
          phx-click={JS.push("remove_person", value: %{"id" => @person.id})}
          class="text-sm font-medium text-ink-soft transition hover:text-bad"
        >
          Remove
        </button>
      </div>

      <ul :if={@person.plus_ones != []} class="mt-1 space-y-0.5 text-sm text-ink-faint">
        <li
          :for={plus_one <- @person.plus_ones}
          id={"what-if-person-#{@person.id}-plus-one-#{plus_one.id}"}
        >
          {plus_one.name} — follows host
        </li>
      </ul>

      <%!-- Compacted (orchestrator amendment, layout compaction): one line per event, no
           per-row border box, the "now: …" caption inline and small; a 2-column grid
           from `md` up so a 5-event person no longer needs five tall rows. --%>
      <ul class="mt-3 grid grid-cols-1 gap-x-6 gap-y-1 md:grid-cols-2">
        <li :for={cell <- @person.cells} class="flex items-center justify-between gap-2 py-1">
          <p class="min-w-0 truncate text-sm text-ink">
            {cell.event_name}
            <span
              :if={cell.real_label}
              class="ml-1 inline-flex items-center gap-1 text-xs text-accent"
            >
              <span
                class="inline-flex size-3 shrink-0 items-center justify-center rounded-full bg-accent text-white"
                title="Your unsaved deviation"
                aria-hidden="true"
              >
                <span class="sr-only">Your unsaved deviation</span>
              </span>
              {cell.real_label}
            </span>
          </p>

          <form
            id={cell.form_id}
            class="contents"
            phx-change={JS.push("set_cell", loading: loading_targets())}
          >
            <input type="hidden" name="person_id" value={@person.id} />
            <input type="hidden" name="event_id" value={cell.event_id} />
            <select
              id={cell.select_id}
              name="status"
              aria-label={"What if #{cell.event_name}"}
              class={[
                "shrink-0 rounded-field border bg-surface-raised px-2 py-1 text-sm focus:border-accent focus:ring-2 focus:ring-accent focus:outline-none sm:w-36",
                if(cell.changed?,
                  do: "border-accent text-accent",
                  else: "border-line-strong text-ink"
                )
              ]}
            >
              <option
                :for={option <- WeddingPlannerWeb.WhatIfView.status_options()}
                value={option.value}
                selected={cell.value == option.value}
              >
                {option.label}
              </option>
            </select>
          </form>
        </li>
      </ul>
    </div>
    """
  end

  # -- preview: headcount ------------------------------------------------------------------------

  @doc "One event's (or 'All events'') headcount row, before → after under each role preset (`HC-03`, `HC-08`)."
  attr :row, :map, required: true
  attr :open_formula_ids, :any, required: true

  def headcount_row(assigns) do
    ~H"""
    <div id={@row.id} class="rounded-field border border-line bg-surface-raised p-4">
      <p class="font-semibold text-ink">{@row.name}</p>

      <div class="mt-2">
        <.role_values
          id={"#{@row.id}-values"}
          ranged={@row.values}
          formula_id={@row.formula_id}
          click_event="select_preset"
          loading_target={loading_targets()}
        />
      </div>

      <div class="mt-3">
        <p class="text-xs text-ink-faint">
          {@row.before_display} <span aria-hidden="true">→</span> {@row.after_display}
        </p>
        <.formula
          id={@row.formula_id}
          open={MapSet.member?(@open_formula_ids, @row.formula_id)}
          {@row.formula}
        />
      </div>
    </div>
    """
  end

  # -- preview: categories ------------------------------------------------------------------------

  @doc "One category whose delta is non-zero under at least one role (`B4`, `BUD-08`)."
  attr :row, :map, required: true
  attr :open_formula_ids, :any, required: true

  def category_row(assigns) do
    ~H"""
    <div id={@row.id} class="rounded-field border border-line bg-surface-raised p-4">
      <p class="font-semibold text-ink">{@row.name}</p>

      <div class="mt-2">
        <.role_values
          id={"#{@row.id}-delta-values"}
          ranged={@row.deltas}
          formula_id={@row.delta_formula_id}
          click_event="select_preset"
          loading_target={loading_targets()}
        />
      </div>

      <div class="mt-3 space-y-3">
        <div>
          <p class="text-xs font-medium tracking-wide text-ink-soft uppercase">Before → after</p>
          <.role_values
            id={"#{@row.id}-before-after-values"}
            ranged={@row.before_after}
            formula_id={@row.after_formula_id}
            click_event="select_preset"
            loading_target={loading_targets()}
          />
        </div>

        <ul :if={@row.offers != []} class="space-y-0.5 text-sm text-ink-soft">
          <li :for={offer <- @row.offers} id={offer.id}>{offer.label}</li>
        </ul>

        <.formula
          id={@row.delta_formula_id}
          open={MapSet.member?(@open_formula_ids, @row.delta_formula_id)}
          {@row.delta_formula}
        />
        <.formula
          id={@row.after_formula_id}
          open={MapSet.member?(@open_formula_ids, @row.after_formula_id)}
          {@row.after_formula}
        />
      </div>
    </div>
    """
  end

  # -- preview: overall ---------------------------------------------------------------------------

  @doc "The overall forecast change and Available after the what-if (`BUD-05`-shaped)."
  attr :overall, :map, required: true
  attr :open_formula_ids, :any, required: true

  def overall(assigns) do
    ~H"""
    <div id="what-if-overall" class="rounded-field border border-line bg-surface-raised p-4">
      <div>
        <p class="text-xs font-medium tracking-wide text-ink-soft uppercase">Change in forecast</p>
        <.role_values
          id="what-if-overall-forecast-change"
          ranged={@overall.forecast_change}
          formula_id={@overall.delta_formula_id}
          click_event="select_preset"
          loading_target={loading_targets()}
        />
      </div>

      <div class="mt-4">
        <p class="text-xs font-medium tracking-wide text-ink-soft uppercase">Available after</p>
        <p
          :if={@overall.available_after == :missing}
          id="what-if-overall-no-budget"
          class="text-sm text-ink-soft"
        >
          Set an overall budget
        </p>
        <.role_values
          :if={@overall.available_after != :missing}
          id="what-if-overall-available-after"
          ranged={@overall.available_after}
          formula_id={@overall.available_formula_id}
          click_event="select_preset"
          loading_target={loading_targets()}
          bad?={@overall.over_budget_after?}
        />
        <p
          :if={@overall.over_budget_after?}
          id="what-if-overall-over-budget"
          class="mt-1 text-sm font-semibold text-bad"
        >
          Over budget by {@overall.over_budget_text}
        </p>
      </div>

      <div class="mt-4 space-y-3">
        <.formula
          id={@overall.delta_formula_id}
          open={MapSet.member?(@open_formula_ids, @overall.delta_formula_id)}
          {@overall.delta_formula}
        />
        <.formula
          :if={@overall.available_formula}
          id={@overall.available_formula_id}
          open={MapSet.member?(@open_formula_ids, @overall.available_formula_id)}
          {@overall.available_formula}
        />
      </div>
    </div>
    """
  end

  # -- Apply confirmation (DR-83) ------------------------------------------------------------------

  @doc """
  The Apply confirmation panel (`DR-83`, `XC-10`/`XC-12`): a bespoke panel rather than
  `WeddingPlannerWeb.CoreComponents.destructive_confirm/1` — Apply is not a delete
  (nothing here is "affected" the way a deletion's referenced rows are; the whole point
  is naming every change being written), so its own confirm/cancel ids and wording say
  exactly that.
  """
  attr :id, :string, default: "what-if-apply-confirm"
  attr :apply, :map, required: true

  def apply_confirm(assigns) do
    ~H"""
    <div
      id={@id}
      role="alertdialog"
      aria-labelledby={"#{@id}-title"}
      class="rounded-field border border-accent/30 bg-accent-soft p-4"
    >
      <p id={"#{@id}-title"} class="text-sm font-semibold text-ink">Apply {@apply.summary}?</p>
      <p :if={@apply.overwrites?} class="mt-1 text-sm text-ink-soft">
        This overwrites an existing RSVP for at least one of these.
      </p>

      <ul id={"#{@id}-changes"} class="mt-3 space-y-1 text-sm text-ink">
        <li :for={change <- @apply.changes} id={change.id}>{change.text}</li>
      </ul>

      <div class="mt-4 flex flex-wrap gap-2">
        <.button variant="primary" id="what-if-apply-confirmed" phx-click="apply_confirmed">
          Confirm
        </.button>
        <.button id="what-if-apply-cancel" phx-click="apply_cancel">
          Cancel
        </.button>
      </div>
    </div>
    """
  end
end
