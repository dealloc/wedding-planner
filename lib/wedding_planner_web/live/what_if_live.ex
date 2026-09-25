defmodule WeddingPlannerWeb.Live.WhatIfLive do
  @moduledoc """
  The what-if screen (task 89; `/what-if`, `DR-82`): pick people who are not counted
  yet (the B-list, `INVT-04`) or a whole group, set hypothetical invitation statuses,
  see — live — the recomputed headcount and forecast per preset, and **Apply** the
  change after a confirmation (`DR-83`) or **Discard** it. `BUD-20`: **nothing is
  written before Apply.**

  Built entirely on `WeddingPlannerWeb.WhatIfView.build/5`, over
  `WeddingPlanner.Valuation.Simulation`'s own result — this module never computes a
  count or an amount itself.

  ## The draft is a transient assign, never URL/session/DB (`DR-80`, `BUD-20`)

  `@draft` (`WeddingPlanner.Valuation.Simulation.draft/0`) lives only in this socket's
  own assigns. `@selected_ids` (the picked person **ids**, in pick order) is view state
  and does live in the URL (`?people=<ids>`, `push_patch` on add/remove) — the two are
  deliberately different: losing the selection on reload is a minor inconvenience
  (re-pick), losing a hypothetical draft you were still composing would not be
  (`BUD-20`'s whole point). `@selected_preset_id` is transient exactly like `/budget`'s
  own (`HC-10`, `D-31`).

  ## +1s follow their host (`PER-13`)

  A +1 id never appears in `@selected_ids` — `handle_params/3` resolves one to its
  host's id before it ever reaches the draft editor (a person page's "What if…" link on
  a +1's own page already sends the host's id, but a garbage/manually-typed +1 id is
  resolved here too, defensively). The URL is then normalized to the resolved,
  deduplicated id list (and the one-shot `?group=` param dropped), so a reload lands on
  the same selection without re-expanding the group every time.

  ## Live updates (`XC-01`) and the draft's own lifecycle (`DR-80`)

  Subscribed to the same topic set `WeddingPlannerWeb.Live.BudgetLive` uses (every
  resource a headcount or a forecast can depend on). On any message: reload the
  snapshot, `Simulation.prune/2` the draft (a person or event deleted meanwhile simply
  drops out — never raises), drop any selected id no longer in the snapshot, and
  recompute — the draft **survives** a live message; only a cell whose real status now
  equals its own hypothetical one stops being a change.

  ## Recomputing the preview is asynchronous (the `/budget` pattern, carried over
  verbatim — orchestrator amendment, loading state & latency)

  `recompute/1` is the single entry point every one of a draft edit, a preset change, a
  picker add/remove and a live message goes through — synchronous only for the very
  first view model (nothing to dim before the page has rendered once), `start_async/3`
  every time after, with `@recomputing` dimming `WhatIfComponents.loading_targets/0`'s
  region while every interactive control *also* carries that same selector as
  `JS.push/2`'s own `:loading` option (or, for a genuine `<form>` submit, the browser's
  own submit-in-flight state), so the dimming is instant, client-side, at click/change
  time (`NFR-33`: preview ≈ 90 ms on the reference fixture, still worth covering).
  """
  use WeddingPlannerWeb, :live_view

  import WeddingPlannerWeb.Components.WhatIfComponents

  alias WeddingPlanner.Guests.Person
  alias WeddingPlanner.Invitations
  alias WeddingPlanner.Realtime
  alias WeddingPlanner.Repo
  alias WeddingPlanner.Valuation.PresetChoice
  alias WeddingPlanner.Valuation.Simulation
  alias WeddingPlanner.Valuation.Snapshot
  alias WeddingPlannerWeb.WhatIfView

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
    :headcount_preset
  ]

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket) do
      Enum.each(@topics, &Realtime.subscribe/1)
    end

    socket =
      socket
      |> assign(:page_title, "What if…")
      |> assign(:draft, %{})
      |> assign(:selected_preset_id, nil)
      |> assign(:open_formula_ids, MapSet.new())
      |> assign(:picker_query, "")
      |> assign(:picker_filters, %{not_counted?: false, maybe?: false})
      |> assign(:confirm_open?, false)
      |> assign(:recomputing, false)
      |> load_snapshot()

    {:ok, socket}
  end

  # -- events (grouped: every `handle_event/3` clause lives together, plan §2's own trap
  # about interleaving them with unrelated `defp`s, which trips Elixir's own
  # "clauses should be grouped together" warning under `--warnings-as-errors`) ------------

  @impl true
  def handle_event("search", %{"q" => query}, socket) do
    {:noreply, assign(socket, :picker_query, query)}
  end

  def handle_event("toggle_filter", %{"filter" => "not_counted"}, socket) do
    {:noreply, update(socket, :picker_filters, &%{&1 | not_counted?: not &1.not_counted?})}
  end

  def handle_event("toggle_filter", %{"filter" => "maybe"}, socket) do
    {:noreply, update(socket, :picker_filters, &%{&1 | maybe?: not &1.maybe?})}
  end

  def handle_event("picker_add", %{"id" => id}, socket) do
    {:noreply, add_ids(socket, [normalize_id(id)])}
  end

  def handle_event("picker_add_group", %{"group_id" => group_id}, socket) do
    ids = group_member_ids(normalize_id(group_id), socket.assigns.snapshot)
    {:noreply, add_ids(socket, ids)}
  end

  def handle_event("remove_person", %{"id" => id}, socket) do
    person_id = normalize_id(id)

    ids = Enum.reject(socket.assigns.selected_ids, &(&1 == person_id))
    draft = Map.delete(socket.assigns.draft, person_id)

    socket =
      socket
      |> assign(:draft, draft)
      |> patch_selection(ids)

    {:noreply, socket}
  end

  def handle_event(
        "set_cell",
        %{"person_id" => person_id, "event_id" => event_id, "status" => status},
        socket
      ) do
    draft =
      update_draft(
        socket.assigns.draft,
        String.to_integer(person_id),
        String.to_integer(event_id),
        status
      )

    {:noreply, socket |> assign(:draft, draft) |> assign_pruned_draft() |> recompute()}
  end

  def handle_event("set_all", %{"event_id" => event_id, "status" => status}, socket) do
    event_id = String.to_integer(event_id)

    draft =
      Enum.reduce(socket.assigns.selected_ids, socket.assigns.draft, fn person_id, draft ->
        update_draft(draft, person_id, event_id, status)
      end)

    {:noreply, socket |> assign(:draft, draft) |> assign_pruned_draft() |> recompute()}
  end

  def handle_event("select_preset", %{"what-if-preset-selector-preset" => id}, socket) do
    {:noreply, socket |> assign(:selected_preset_id, id) |> recompute()}
  end

  def handle_event("select_preset", %{"preset_id" => id} = params, socket) do
    socket =
      socket
      |> assign(:selected_preset_id, id)
      |> mark_formula_open(params["formula_id"])
      |> recompute()

    {:noreply, socket}
  end

  def handle_event("open_apply_confirm", _params, socket) do
    {:noreply, assign(socket, :confirm_open?, true)}
  end

  def handle_event("apply_cancel", _params, socket) do
    {:noreply, assign(socket, :confirm_open?, false)}
  end

  def handle_event("apply_confirmed", _params, socket) do
    scope = socket.assigns.current_scope
    snapshot = socket.assigns.snapshot
    pruned = Simulation.prune(snapshot, socket.assigns.draft)

    cells =
      snapshot
      |> Simulation.changed_cells(pruned)
      |> Enum.map(&%{person: &1.person, event: &1.event, status: &1.to})

    case Invitations.apply_what_if(scope, cells) do
      {:ok, changed} ->
        socket =
          socket
          |> assign(:draft, %{})
          |> assign(:confirm_open?, false)
          |> put_flash(:info, WhatIfView.applied_flash(length(changed)))
          |> load_snapshot()
          |> recompute()

        {:noreply, socket}

      {:error, :stale} ->
        socket =
          socket
          |> assign(:confirm_open?, false)
          |> put_flash(
            :error,
            "Something changed while you were planning — review and apply again"
          )
          |> load_snapshot()
          |> recompute()

        {:noreply, socket}

      {:error, :plus_one} ->
        # Unreachable (`DR-83`): `pruned` never carries a +1 (`Simulation.prune/2`,
        # `PER-13`) — a hard crash here is a bug in this module, never a user action.
        raise "apply_what_if/2 refused a +1 after prune/2 — this should be unreachable"
    end
  end

  def handle_event("discard", _params, socket) do
    {:noreply, socket |> assign(:draft, %{}) |> assign(:confirm_open?, false) |> recompute()}
  end

  # -- live updates (XC-01) -----------------------------------------------------------------

  @impl true
  def handle_info({Realtime, _resource, _event}, socket) do
    socket = socket |> load_snapshot() |> prune_selection() |> recompute()
    {:noreply, socket}
  end

  # -- the async view-model recompute -------------------------------------------------------

  @impl true
  def handle_async(:build_vm, {:ok, {preset_id, ids, vm}}, socket) do
    socket =
      if preset_id == socket.assigns.selected_preset_id and ids == socket.assigns.selected_ids do
        socket |> assign(:vm, vm) |> assign(:recomputing, false)
      else
        # Stale — a newer selection/preset is already in flight (defensive backstop;
        # `start_async/3` itself already discards this by name, see `BudgetLive`).
        socket
      end

    {:noreply, socket}
  end

  def handle_async(:build_vm, {:exit, _reason}, socket) do
    {:noreply, assign(socket, :recomputing, false)}
  end

  # -- selection (`?people=`/`?group=`, DR-82) ----------------------------------------------

  @impl true
  def handle_params(params, _uri, socket) do
    snapshot = socket.assigns.snapshot

    ids =
      (parse_ids(params["people"], snapshot) ++ group_member_ids(params["group"], snapshot))
      |> resolve_plus_ones(snapshot)
      |> Enum.uniq()

    socket =
      socket
      |> assign(:selected_ids, ids)
      |> maybe_normalize_url(params, ids)
      |> recompute()

    {:noreply, socket}
  end

  defp parse_ids(nil, _snapshot), do: []

  defp parse_ids(param, %Snapshot{} = snapshot) when is_binary(param) do
    wanted = param |> String.split(",", trim: true) |> MapSet.new(&String.trim/1)
    for person <- snapshot.persons, MapSet.member?(wanted, to_string(person.id)), do: person.id
  end

  defp parse_ids(_param, _snapshot), do: []

  defp group_member_ids(nil, _snapshot), do: []

  defp group_member_ids(group_id, %Snapshot{} = snapshot) when is_binary(group_id) do
    group_member_ids_by_id(String.trim(group_id), snapshot)
  end

  defp group_member_ids(group_id, %Snapshot{} = snapshot) do
    group_member_ids_by_id(group_id, snapshot)
  end

  defp group_member_ids_by_id(group_id, snapshot) do
    case Enum.find(snapshot.groups, &(to_string(&1.id) == to_string(group_id))) do
      nil -> []
      group -> for p <- snapshot.persons, is_nil(p.host_id), p.group_id == group.id, do: p.id
    end
  end

  # PER-13: a +1 never gets its own draft-editor card — its id always resolves to its
  # host's before it ever reaches `@selected_ids`.
  defp resolve_plus_ones(ids, %Snapshot{} = snapshot) do
    by_id = Map.new(snapshot.persons, &{&1.id, &1})

    for id <- ids,
        person = Map.get(by_id, id),
        not is_nil(person) do
      case person do
        %Person{host_id: nil} -> id
        %Person{host_id: host_id} -> host_id
      end
    end
  end

  # Drops the one-shot `?group=` param and rewrites `?people=` to the resolved,
  # deduplicated id list, so a reload lands on the same selection without re-expanding
  # the group (or re-resolving a +1) every time. A no-op (no `push_patch`) once the URL
  # already matches, so this cannot loop.
  defp maybe_normalize_url(socket, params, ids) do
    desired = if ids == [], do: nil, else: Enum.join(ids, ",")
    changed? = Map.has_key?(params, "group") or desired != params["people"]

    if connected?(socket) and changed? do
      path = if desired, do: ~p"/what-if?people=#{desired}", else: ~p"/what-if"
      push_patch(socket, to: path, replace: true)
    else
      socket
    end
  end

  defp add_ids(socket, new_ids) do
    ids =
      (socket.assigns.selected_ids ++ resolve_plus_ones(new_ids, socket.assigns.snapshot))
      |> Enum.uniq()

    patch_selection(socket, ids)
  end

  defp patch_selection(socket, ids) do
    path = if ids == [], do: ~p"/what-if", else: ~p"/what-if?people=#{Enum.join(ids, ",")}"
    push_patch(socket, to: path)
  end

  # -- draft editing (DR-80) -----------------------------------------------------------------

  defp update_draft(draft, person_id, event_id, status) do
    events = draft |> Map.get(person_id, %{}) |> Map.put(event_id, status_atom(status))
    Map.put(draft, person_id, events)
  end

  defp status_atom("not_invited"), do: :not_invited
  defp status_atom("planned"), do: :planned
  defp status_atom("invited"), do: :invited
  defp status_atom("accepted"), do: :accepted
  defp status_atom("declined"), do: :declined

  defp mark_formula_open(socket, nil), do: socket
  defp mark_formula_open(socket, id), do: update(socket, :open_formula_ids, &MapSet.put(&1, id))

  # A JS.push `value:` map (unlike an HTML `<form>`'s own params) round-trips a JSON
  # number as an Elixir integer, not a string — `picker_add`/`remove_person`/
  # `picker_add_group` all read an id this way, so this normalizes either shape to the
  # same comparable term without ever calling `String.to_integer/1` on a value that
  # might already be one (which would raise). Person/event/group ids are always plain
  # DB integers in this app (never the `{:what_if, ...}` tagged tuple, which only ever
  # appears on a hypothetical *invitation* row — see `Simulation`'s moduledoc), so this
  # never needs to fall back to a bare string.
  defp normalize_id(id) when is_integer(id), do: id

  defp normalize_id(id) when is_binary(id) do
    case Integer.parse(id) do
      {int, ""} -> int
      _ -> id
    end
  end

  # -- private: snapshot / selection lifecycle ------------------------------------------------

  defp load_snapshot(socket) do
    snapshot = Snapshot.load(Repo)
    draft = Simulation.prune(snapshot, socket.assigns[:draft] || %{})

    socket
    |> assign(:snapshot, snapshot)
    |> assign(:draft, draft)
  end

  defp assign_pruned_draft(socket) do
    assign(socket, :draft, Simulation.prune(socket.assigns.snapshot, socket.assigns.draft))
  end

  defp prune_selection(socket) do
    ids = MapSet.new(socket.assigns.snapshot.persons, & &1.id)
    kept = Enum.filter(socket.assigns.selected_ids, &MapSet.member?(ids, &1))
    assign(socket, :selected_ids, kept)
  end

  # -- private: the async view-model recompute (the `/budget` pattern) ------------------------

  defp recompute(socket) do
    if Map.has_key?(socket.assigns, :vm) do
      recompute_async(socket)
    else
      assign_vm_sync(socket)
    end
  end

  defp assign_vm_sync(socket) do
    socket
    |> assign(:vm, build_vm(socket.assigns))
    |> assign(:recomputing, false)
  end

  defp recompute_async(socket) do
    %{
      snapshot: snapshot,
      draft: draft,
      selected_ids: selected_ids,
      selected_preset_id: preset_id
    } = socket.assigns

    socket
    |> assign(:recomputing, true)
    |> start_async(:build_vm, fn ->
      vm =
        build_vm(%{
          snapshot: snapshot,
          draft: draft,
          selected_ids: selected_ids,
          selected_preset_id: preset_id
        })

      {preset_id, selected_ids, vm}
    end)
  end

  defp build_vm(%{
         snapshot: snapshot,
         draft: draft,
         selected_ids: selected_ids,
         selected_preset_id: selected_preset_id
       }) do
    preview = preview_for(snapshot, draft, selected_preset_id)

    selection =
      for id <- selected_ids,
          person = find_person(snapshot, id),
          not is_nil(person),
          do: person

    WhatIfView.build(preview, snapshot, selection, draft, selected_preset_id)
  end

  defp preview_for(snapshot, draft, selected_preset_id) do
    case PresetChoice.find(snapshot.headcount_presets, selected_preset_id) do
      nil ->
        :missing

      preset ->
        case Simulation.baseline(snapshot, preset) do
          {:ok, baseline} -> Simulation.preview(baseline, draft)
          :missing -> :missing
        end
    end
  end

  defp find_person(snapshot, id), do: Enum.find(snapshot.persons, &(&1.id == id))

  # -- picker filtering (plain string/boolean matching, not a business rule) ------------------

  defp filtered_picker_results(candidates, query, filters) do
    candidates
    |> filter_by_query(query)
    |> filter_by_chip(filters.not_counted?, & &1.not_counted_under_likely?)
    |> filter_by_chip(filters.maybe?, & &1.want_maybe?)
  end

  defp filter_by_query(candidates, query) when query in [nil, ""], do: candidates

  defp filter_by_query(candidates, query) do
    needle = String.downcase(query)
    Enum.filter(candidates, &String.contains?(String.downcase(&1.name), needle))
  end

  defp filter_by_chip(candidates, false, _fun), do: candidates
  defp filter_by_chip(candidates, true, fun), do: Enum.filter(candidates, fun)

  defp pluralize_categories(1), do: "category"
  defp pluralize_categories(_n), do: "categories"

  # -- render --------------------------------------------------------------------------------

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_scope={@current_scope}>
      <WeddingPlannerWeb.Live.TimeZoneHook.probe id="what-if-time-zone-probe" />

      <div class="mx-auto max-w-3xl">
        <div id="what-if-header" class="flex flex-wrap items-start justify-between gap-4">
          <div>
            <h1 class="text-2xl font-bold text-ink">What if…</h1>
            <p class="mt-1 text-sm text-ink-soft">
              Try invitation changes and see what they cost. Nothing is saved until you apply.
            </p>
          </div>

          <div :if={!@vm.presets_missing?} class="flex flex-col items-end gap-1">
            <.form
              for={to_form(%{}, as: :what_if_preset)}
              id="what-if-preset"
              phx-change={JS.push("select_preset", loading: loading_targets())}
              class="contents"
            >
              <.preset_selector
                id="what-if-preset-selector"
                presets={@vm.preset_selector.presets}
                selected={@vm.preset_selector.selected}
              />
            </.form>
            <p class="text-xs text-ink-faint">Used for calculations; not saved</p>
          </div>
        </div>

        <p :if={@vm.presets_missing?} id="what-if-no-presets" class="mt-6 text-sm text-ink-soft">
          No headcount presets are stored, so this can't be computed right now.
        </p>

        <div class="mt-4">
          <.picker
            open?={@selected_ids == []}
            likely_preset_name={@vm.likely_preset_name}
            query={@picker_query}
            not_counted?={@picker_filters.not_counted?}
            maybe?={@picker_filters.maybe?}
            results={filtered_picker_results(@vm.picker_candidates, @picker_query, @picker_filters)}
            groups={@vm.groups}
          />
        </div>

        <div id="what-if-people" class="mt-4 space-y-3">
          <p :if={!@vm.has_selection?} id="what-if-people-empty" class="text-sm text-ink-faint">
            Pick people above — for example the B-list: want tier maybe, not counted yet.
          </p>

          <.person_card :for={person <- @vm.person_cards} person={person} />

          <.form
            :if={@vm.has_selection?}
            for={to_form(%{}, as: :what_if_set_all)}
            id="what-if-set-all"
            phx-submit="set_all"
            class="flex flex-wrap items-end gap-2 rounded-field border border-line bg-surface-raised p-3 phx-submit-loading:opacity-60"
          >
            <.input
              type="select"
              name="event_id"
              id="what-if-set-all-event"
              label="Set for everyone here"
              value={nil}
              options={Enum.map(@vm.events, &{&1.name, &1.id})}
            />
            <.input
              type="select"
              name="status"
              id="what-if-set-all-status"
              label="Status"
              value={nil}
              options={Enum.map(@vm.status_options, &{&1.label, &1.value})}
            />
            <.button variant="secondary" id="what-if-set-all-submit">Set</.button>
          </.form>
        </div>

        <div
          id="what-if-preview"
          class={[
            "mt-6 space-y-4 transition-opacity phx-click-loading:opacity-50 phx-change-loading:opacity-50",
            @recomputing && "opacity-50"
          ]}
          aria-busy={to_string(@recomputing)}
        >
          <div class="flex items-center gap-2">
            <p id="what-if-summary" class="text-sm font-medium text-ink">{@vm.summary}</p>
            <p
              :if={@recomputing}
              id="what-if-recomputing"
              aria-live="polite"
              class="flex items-center gap-1.5 text-xs text-ink-faint"
            >
              <span
                class="size-3 shrink-0 animate-spin rounded-full border-2 border-ink-faint border-t-transparent"
                aria-hidden="true"
              ></span>
              Updating…
            </p>
            <%!-- The client-side twin of #what-if-recomputing: every recomputing control's
                 JS.push (or, for a real form submit, the browser's own submit-loading
                 class) names it as a loading target, so it shows from the click until the
                 reply is acknowledged, before the server's @recomputing can reach the page. --%>
            <p
              :if={!@recomputing}
              id="what-if-updating"
              class="hidden items-center gap-1.5 text-xs text-ink-faint phx-click-loading:flex phx-change-loading:flex phx-submit-loading:flex"
            >
              <span
                class="size-3 shrink-0 animate-spin rounded-full border-2 border-ink-faint border-t-transparent"
                aria-hidden="true"
              ></span>
              Updating…
            </p>
          </div>

          <div :if={!@vm.presets_missing?} id="what-if-headcount" class="space-y-3">
            <.headcount_row
              :for={row <- @vm.headcount_rows}
              row={row}
              open_formula_ids={@open_formula_ids}
            />
          </div>

          <div :if={!@vm.presets_missing?} id="what-if-categories" class="space-y-3">
            <.category_row
              :for={row <- @vm.category_rows}
              row={row}
              open_formula_ids={@open_formula_ids}
            />
            <p id="what-if-categories-unchanged" class="text-sm text-ink-faint">
              {@vm.categories_unchanged_count} {pluralize_categories(@vm.categories_unchanged_count)} unchanged
            </p>
          </div>

          <.overall
            :if={@vm.overall != :missing}
            overall={@vm.overall}
            open_formula_ids={@open_formula_ids}
          />
        </div>

        <div id="what-if-actions" class="mt-6 space-y-3">
          <div class="flex flex-wrap gap-2">
            <.button
              variant="primary"
              id="what-if-apply"
              phx-click="open_apply_confirm"
              disabled={!@vm.has_changes?}
            >
              Apply
            </.button>
            <.button id="what-if-discard" phx-click="discard">Discard</.button>
          </div>

          <.apply_confirm :if={@confirm_open?} apply={@vm.apply} />
        </div>
      </div>
    </Layouts.app>
    """
  end
end
