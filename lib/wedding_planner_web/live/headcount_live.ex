defmodule WeddingPlannerWeb.Live.HeadcountLive do
  @moduledoc """
  `/headcount` (task 61; `docs/modules/headcount.md` `HC-03`, `HC-07`, `HC-08`, `HC-09`;
  `DR-55`): events × presets, an "All events" row of distinct persons, every count
  openable into who is counted and why (`NFR-32`), and an ad hoc, unsaved filter
  (`HC-07`) that adds one more column and can be saved as a stored preset.

  ## Data (`HC-01`: never stored, computed live)

  `WeddingPlannerWeb.HeadcountOverview.build/2` — the pure view-model builder — turns a
  fresh `WeddingPlanner.Valuation.Snapshot.load/1` plus the transient ad hoc
  `WeddingPlanner.Valuation.Preset` (or `nil`) into `@overview.rows`/`@overview.columns`;
  this module only renders it. `refresh/1` reloads the snapshot from the database and
  rebuilds `@overview` — called on mount and on every `:person`, `:group`, `:invitation`,
  `:plus_one_opt_out`, `:event`, `:headcount_preset` broadcast (`WeddingPlanner.Realtime`,
  `XC-01`) — so a change made in another tab (or another LiveView, e.g. an RSVP set on
  `/invitations`) appears here without a reload, never from a cached snapshot. No change
  indicator of any kind (`DR-6`, `DR-21`).

  ## The ad hoc filter (`HC-07`, `HC-10`, `D-31`)

  `@adhoc_params` is the raw, string-keyed form params (`phx-change` lives on
  `#adhoc-filter-form`, never a bare checkbox — the design record's matrix-v3 bug);
  `@adhoc_preset` is the `WeddingPlanner.Valuation.Preset` built from it (`id: nil`,
  `name: "Ad hoc filter"`), or `nil` when the filter has never been touched this
  connection. Both are **transient socket assigns only** — never written to the
  database, the session or a broadcast (`HC-10`) — so the ad hoc column exists only for
  as long as this LiveView process lives. Each of the five checkbox groups carries a
  hidden `value=""` input alongside its `name="adhoc[<field>][]"` checkboxes so that
  unchecking the last box in a group still submits the key (with an empty value, which
  `filter_adhoc_params/1` strips) rather than dropping it from the params entirely — the
  well-known "browsers don't send unchecked checkboxes" gotcha, doubled for an array
  name. "Clear" (`#adhoc-filter-clear`) resets both assigns and removes the column.

  "Save as preset" (`#adhoc-save-form`) reuses `@adhoc_params` verbatim as the attrs for
  `WeddingPlanner.Presets.create_preset/2` (its keys already match
  `WeddingPlanner.Presets.HeadcountPreset`'s castable fields) plus the submitted name.
  On success the ad hoc column is cleared — the new preset reappears as an ordinary
  column via the `:headcount_preset` broadcast's own `refresh/1`, never assumed
  synchronously. On failure (e.g. a duplicate name) the changeset error renders inline
  and nothing is cleared, so the user's filter and typed name are not lost.

  ## Cell disclosure (`NFR-32`, `HC-08`, `DR-55`)

  Each cell is its own native `<details>` (`#headcount-cell-<row>-<col>`) whose
  `<summary>` is the plain "adults + children = total" text; its body nests
  `WeddingPlannerWeb.DisplayComponents.formula/1` (`#…-formula`, rendered `open`, so the
  formula's own step breakdown needs no second click — NFR-32's "at most one
  interaction" would otherwise mean two nested disclosures) fed by
  `WeddingPlannerWeb.FormulaPresenter.present/1` of
  `WeddingPlanner.Valuation.Headcount.explain/3`, plus a "Who is counted" names list
  (`#…-names`) from `WeddingPlanner.Valuation.Headcount.counted/3`.

  ## Preset management (task 62, `DR-53`, `DR-55`, `DR-54` **revised**)

  `#presets-section`, below the overview and the ad hoc filter, lists every stored
  preset in sort order: name, a one-line criteria summary, up/down reorder, and — for a
  **custom** preset only — Edit and Delete.

  **`DR-54` revised (binding orchestrator ruling, 2026-09-24):** the three seeded
  defaults (`preset.role != nil`) are locked — no rename, no criteria edit, no role
  change (there is no role picker anywhere any more; `WeddingPlanner.Presets` never
  casts `role`), no delete. A default's row shows its name, criteria summary and a
  neutral "Default (locked)" pill (a role is not a status, so never the accent tone)
  with no Edit/Delete controls; `edit_preset`/`confirm_delete_preset` refuse a locked
  preset's id defensively even so (a client can still send an arbitrary
  `phx-value-id`). **Unaffected:** up/down reorder stays available to every preset,
  defaults included — list order is presentation, not a preset's identity.

  **One editor open at a time** (`@editing_preset_id`: `nil` | a custom preset's id |
  `:new` — same contract as `offer_live.ex`'s `@editing_line_id`); `#preset-form` is the
  one open editor, built from `WeddingPlanner.Presets.change_preset/2` and saved through
  `WeddingPlanner.Presets.create_preset/2`/`update_preset/3`. Deleting goes through
  `CoreComponents.destructive_confirm/1`, `:affected` fed from
  `WeddingPlanner.Presets.preset_deletion_effects/1` (a plain `[String.t()]`, always
  `[]` now that only a custom preset ever reaches it — wrapped here as `%{label:
  string, count: 1}` for the component's shape; the context function's own return type
  is untouched). Each preset's history (defaults included) is a `<details>` disclosure
  around `WeddingPlannerWeb.ActivityComponents.entity_history/1`, kept live by
  `:activity_entry` broadcasts (same idiom as `category_live.ex`'s `service_histories`):
  fetched once per preset id and reconciled (never refetched wholesale) whenever
  `@presets` changes, then grown in place as entries for `"headcount_preset"` arrive.
  """
  use WeddingPlannerWeb, :live_view

  import WeddingPlannerWeb.ActivityComponents, only: [entity_history: 1]
  import WeddingPlannerWeb.Components.ExportComponents, only: [export_link: 1]

  alias WeddingPlanner.Log.Query
  alias WeddingPlanner.Presets
  alias WeddingPlanner.Presets.HeadcountPreset
  alias WeddingPlanner.Realtime
  alias WeddingPlanner.Repo
  alias WeddingPlanner.Valuation.Preset
  alias WeddingPlanner.Valuation.Snapshot
  alias WeddingPlannerWeb.HeadcountOverview

  on_mount {WeddingPlannerWeb.Live.TimeZoneHook, :default}

  @status_options [
    {"Planned", "planned"},
    {"Invited", "invited"},
    {"Accepted", "accepted"},
    {"Declined", "declined"}
  ]

  @certainty_options [{"Certain", "certain"}, {"Likely", "likely"}, {"Uncertain", "uncertain"}]

  @want_tier_options [
    {"Yes", "yes"},
    {"Maybe", "maybe"},
    {"No", "no"},
    {"Obligated", "obligated"}
  ]

  @age_category_options [{"Adult", "adult"}, {"Child", "child"}]

  @adhoc_fields ~w(invitation_statuses certainties want_tiers age_categories group_ids)
  @default_adhoc_params Map.new(@adhoc_fields, &{&1, []})
  @preset_array_fields @adhoc_fields

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket) do
      Realtime.subscribe(:person)
      Realtime.subscribe(:group)
      Realtime.subscribe(:invitation)
      Realtime.subscribe(:plus_one_opt_out)
      Realtime.subscribe(:event)
      Realtime.subscribe(:headcount_preset)
      Realtime.subscribe(:activity_entry)
    end

    socket =
      socket
      |> assign(:page_title, "Headcount")
      |> assign(:adhoc_params, @default_adhoc_params)
      |> assign(:adhoc_preset, nil)
      |> assign(:save_form, blank_save_form())
      |> assign(:status_options, @status_options)
      |> assign(:certainty_options, @certainty_options)
      |> assign(:want_tier_options, @want_tier_options)
      |> assign(:age_category_options, @age_category_options)
      |> assign(:editing_preset_id, nil)
      |> assign(:preset_form, nil)
      |> assign(:confirming_delete_preset_id, nil)
      |> assign(:preset_histories, %{})
      |> refresh()

    {:ok, socket}
  end

  # -- ad hoc filter (HC-07, HC-10) ----------------------------------------------------------

  @impl true
  def handle_event("adhoc_filter", %{"adhoc" => params}, socket) do
    filtered = filter_adhoc_params(params)

    socket =
      socket
      |> assign(:adhoc_params, filtered)
      |> assign(:adhoc_preset, build_adhoc_preset(filtered))
      |> refresh()

    {:noreply, socket}
  end

  def handle_event("adhoc_clear", _params, socket) do
    socket =
      socket
      |> assign(:adhoc_params, @default_adhoc_params)
      |> assign(:adhoc_preset, nil)
      |> assign(:save_form, blank_save_form())
      |> refresh()

    {:noreply, socket}
  end

  def handle_event("adhoc_save", %{"preset_save" => %{"name" => name}}, socket) do
    attrs = Map.put(socket.assigns.adhoc_params, "name", name)

    case Presets.create_preset(socket.assigns.current_scope, attrs) do
      {:ok, preset} ->
        socket =
          socket
          |> assign(:adhoc_params, @default_adhoc_params)
          |> assign(:adhoc_preset, nil)
          |> assign(:save_form, blank_save_form())
          |> put_flash(:info, "Saved preset '#{preset.name}'.")
          |> refresh()

        {:noreply, socket}

      {:error, changeset} ->
        {:noreply, assign(socket, :save_form, to_form(changeset, as: "preset_save"))}
    end
  end

  # -- preset management (task 62, DR-53, DR-54, DR-55) --------------------------------------

  def handle_event("new_preset", _params, socket) do
    {:noreply, open_preset_editor(socket, :new)}
  end

  # `DR-54` revised: a locked default (`role != nil`) has no editor at all — the row
  # renders no Edit button, but the guard here is the real enforcement (a client can
  # still send an arbitrary `phx-value-id`; `WeddingPlanner.Presets.update_preset/3`
  # would refuse the eventual save anyway, but there is no reason to even open the form).
  def handle_event("edit_preset", %{"id" => id}, socket) do
    case Presets.get_preset!(id) do
      %HeadcountPreset{role: nil} = preset -> {:noreply, open_preset_editor(socket, preset)}
      %HeadcountPreset{} -> {:noreply, socket}
    end
  end

  def handle_event("cancel_preset_edit", _params, socket) do
    {:noreply, close_preset_editor(socket)}
  end

  def handle_event("validate_preset", %{"preset" => params}, socket) do
    attrs = filter_preset_params(params)

    changeset =
      socket
      |> editing_base_preset()
      |> Presets.change_preset(attrs)
      |> Map.put(:action, :validate)

    {:noreply, assign(socket, :preset_form, to_form(changeset, as: "preset"))}
  end

  def handle_event("save_preset", %{"preset" => params}, socket) do
    attrs = filter_preset_params(params)
    scope = socket.assigns.current_scope

    result =
      case socket.assigns.editing_preset_id do
        :new -> Presets.create_preset(scope, attrs)
        id when is_integer(id) -> Presets.update_preset(scope, Presets.get_preset!(id), attrs)
      end

    case result do
      {:ok, _preset} ->
        {:noreply, socket |> close_preset_editor() |> refresh()}

      # Defensive only: `edit_preset` above never opens this editor for a locked
      # default, so `editing_preset_id` here is always `:new` or a custom preset's id —
      # `Presets.update_preset/3` can never actually return this for either.
      {:error, :default_preset_locked} ->
        {:noreply, socket |> close_preset_editor() |> refresh()}

      {:error, changeset} ->
        {:noreply, assign(socket, :preset_form, to_form(changeset, as: "preset"))}
    end
  end

  def handle_event("move_preset_up", %{"id" => id}, socket), do: move_preset(socket, id, :up)
  def handle_event("move_preset_down", %{"id" => id}, socket), do: move_preset(socket, id, :down)

  # `DR-54` revised: a locked default has no Delete button (reorder stays available to
  # every preset, defaults included — see `move_preset/3` above, unguarded). Same
  # trust-boundary defense as `edit_preset`.
  def handle_event("confirm_delete_preset", %{"id" => id}, socket) do
    case Presets.get_preset!(id) do
      %HeadcountPreset{role: nil} = preset ->
        {:noreply, assign(socket, :confirming_delete_preset_id, preset.id)}

      %HeadcountPreset{} ->
        {:noreply, socket}
    end
  end

  def handle_event("cancel_delete_preset", _params, socket) do
    {:noreply, assign(socket, :confirming_delete_preset_id, nil)}
  end

  def handle_event("delete_preset_confirmed", %{"id" => id}, socket) do
    preset = Presets.get_preset!(id)

    socket =
      case Presets.delete_preset(socket.assigns.current_scope, preset) do
        {:ok, _} ->
          socket
          |> assign(:confirming_delete_preset_id, nil)
          |> maybe_close_editor(preset.id)
          |> refresh()

        # Defensive only: `confirm_delete_preset` above never confirms a locked
        # default, so this can never actually happen through the UI.
        {:error, :default_preset_locked} ->
          assign(socket, :confirming_delete_preset_id, nil)
      end

    {:noreply, socket}
  end

  # -- live updates (XC-01, DR-21 — silent, full refresh, never a cached snapshot) -----------

  @impl true
  def handle_info({Realtime, :person, _event}, socket), do: {:noreply, refresh(socket)}
  def handle_info({Realtime, :group, _event}, socket), do: {:noreply, refresh(socket)}
  def handle_info({Realtime, :invitation, _event}, socket), do: {:noreply, refresh(socket)}
  def handle_info({Realtime, :plus_one_opt_out, _event}, socket), do: {:noreply, refresh(socket)}
  def handle_info({Realtime, :event, _event}, socket), do: {:noreply, refresh(socket)}
  def handle_info({Realtime, :headcount_preset, _event}, socket), do: {:noreply, refresh(socket)}

  # `entity_type` is stored as a string (`Log.Entry`'s own column); only entries for a
  # preset this page already tracks the history of are appended — never a wholesale
  # refetch (same idiom as `category_live.ex`'s `service_histories`). Deduped by entry
  # id: a mutation made through this same LiveView (e.g. `save_preset`) calls `refresh/1`
  # directly, which already picks up the entry through `reconcile_preset_histories/2`'s
  # first-seen query — the `:activity_entry` broadcast for that same entry then arrives
  # a moment later and must not append it a second time.
  def handle_info({Realtime, :activity_entry, {:created, entry}}, socket) do
    if entry.entity_type == "headcount_preset" and
         Map.has_key?(socket.assigns.preset_histories, entry.entity_id) do
      socket =
        update(socket, :preset_histories, fn histories ->
          Map.update!(histories, entry.entity_id, fn entries ->
            if Enum.any?(entries, &(&1.id == entry.id)) do
              entries
            else
              [Query.preload_user(entry) | entries]
            end
          end)
        end)

      {:noreply, socket}
    else
      {:noreply, socket}
    end
  end

  # -- data (HC-01: computed fresh every time, never cached across a broadcast) --------------

  defp refresh(socket) do
    snapshot = Snapshot.load(Repo)
    overview = HeadcountOverview.build(snapshot, socket.assigns.adhoc_preset)

    socket
    |> assign(:events, snapshot.events)
    |> assign(:presets, snapshot.headcount_presets)
    |> assign(:groups, snapshot.groups)
    |> assign(:overview, overview)
    |> reconcile_preset_histories(snapshot.headcount_presets)
  end

  # Never a wholesale requery (`:activity_entry`'s handler grows each list in place):
  # keep an existing preset's history untouched, drop histories for a preset that no
  # longer exists, and fetch once for a preset id seen here for the first time (a
  # freshly created preset, or the very first `refresh/1` on mount).
  defp reconcile_preset_histories(socket, presets) do
    ids = MapSet.new(presets, & &1.id)

    histories =
      socket.assigns
      |> Map.get(:preset_histories, %{})
      |> Map.filter(fn {id, _entries} -> MapSet.member?(ids, id) end)

    histories =
      Enum.reduce(presets, histories, fn preset, acc ->
        Map.put_new_lazy(acc, preset.id, fn -> Query.for_entity(:headcount_preset, preset.id) end)
      end)

    assign(socket, :preset_histories, histories)
  end

  defp blank_save_form, do: to_form(%{"name" => ""}, as: "preset_save")

  # `Map.get(params, field, [])`, never `String.to_atom/1`: unknown/blank strings are
  # simply dropped — a checkbox's `value` is always one of the fixed atoms below, and the
  # hidden empty-value input's "" is filtered here.
  defp filter_adhoc_params(params) do
    Map.new(@adhoc_fields, fn field ->
      values = params |> Map.get(field, []) |> List.wrap() |> Enum.reject(&(&1 == ""))
      {field, values}
    end)
  end

  defp build_adhoc_preset(params) do
    %Preset{
      id: nil,
      name: "Ad hoc filter",
      invitation_statuses: parse_set(params["invitation_statuses"], &parse_status/1),
      certainties: parse_set(params["certainties"], &parse_certainty/1),
      want_tiers: parse_set(params["want_tiers"], &parse_want_tier/1),
      age_categories: parse_set(params["age_categories"], &parse_age_category/1),
      group_ids: parse_set(params["group_ids"], &parse_group_id/1)
    }
  end

  defp parse_set(values, parser), do: values |> Enum.map(parser) |> MapSet.new()

  defp parse_status("planned"), do: :planned
  defp parse_status("invited"), do: :invited
  defp parse_status("accepted"), do: :accepted
  defp parse_status("declined"), do: :declined

  defp parse_certainty("certain"), do: :certain
  defp parse_certainty("likely"), do: :likely
  defp parse_certainty("uncertain"), do: :uncertain

  defp parse_want_tier("yes"), do: :yes
  defp parse_want_tier("maybe"), do: :maybe
  defp parse_want_tier("no"), do: :no
  defp parse_want_tier("obligated"), do: :obligated

  defp parse_age_category("adult"), do: :adult
  defp parse_age_category("child"), do: :child

  defp parse_group_id(str) do
    case Integer.parse(str) do
      {id, ""} -> id
      _other -> nil
    end
  end

  # -- preset management helpers (task 62) ---------------------------------------------------

  # Canonical display order for each criterion, as atoms (`preset.invitation_statuses`
  # etc are `MapSet`s of atoms — the set's own enumeration order is undefined). Matches
  # `HeadcountPreset.changeset/2`'s own `dedupe_ordered/3` fixed order, so a preset's
  # summary and its stored order agree.
  @status_order ~w(planned invited accepted declined)a
  @certainty_order ~w(certain likely uncertain)a
  @want_tier_order ~w(yes maybe no obligated)a
  @age_category_order ~w(adult child)a

  defp open_preset_editor(socket, :new) do
    changeset = Presets.change_preset(%HeadcountPreset{}, %{})

    socket
    |> assign(:editing_preset_id, :new)
    |> assign(:preset_form, to_form(changeset, as: "preset"))
  end

  defp open_preset_editor(socket, %HeadcountPreset{} = preset) do
    changeset = Presets.change_preset(preset, %{})

    socket
    |> assign(:editing_preset_id, preset.id)
    |> assign(:preset_form, to_form(changeset, as: "preset"))
  end

  defp close_preset_editor(socket) do
    socket
    |> assign(:editing_preset_id, nil)
    |> assign(:preset_form, nil)
  end

  defp maybe_close_editor(socket, preset_id) do
    if socket.assigns.editing_preset_id == preset_id do
      close_preset_editor(socket)
    else
      socket
    end
  end

  defp editing_base_preset(socket) do
    case socket.assigns.editing_preset_id do
      :new -> %HeadcountPreset{}
      id when is_integer(id) -> Presets.get_preset!(id)
    end
  end

  defp move_preset(socket, id, direction) do
    preset = Presets.get_preset!(id)
    :ok = Presets.move_preset(socket.assigns.current_scope, preset, direction)
    {:noreply, refresh(socket)}
  end

  # Same hidden-empty-value trick as `filter_adhoc_params/1` (`preset[<field>][]`
  # instead of `adhoc[<field>][]`); `role` and `name` pass through unchanged (an empty
  # `role` casts to `nil` via `Ecto.Changeset.cast/4`'s `:empty_values`, never dropped).
  defp filter_preset_params(params) do
    Map.new(params, fn
      {field, values} when field in @preset_array_fields ->
        {field, values |> List.wrap() |> Enum.reject(&(&1 == ""))}

      other ->
        other
    end)
  end

  defp form_selected_strings(form, field) do
    form[field].value |> List.wrap() |> Enum.map(&to_string/1)
  end

  # `HC-06`'s deletion effects (`Presets.preset_deletion_effects/1`, a plain
  # `[String.t()]`) wrapped as `destructive_confirm/1`'s `%{label:, count:}` shape —
  # `count` is never rendered by that component, only `label`, so `1` is a placeholder.
  # `preset` here is the row's `WeddingPlanner.Valuation.Preset` (from `@presets`, i.e.
  # `snapshot.headcount_presets`) — `preset_deletion_effects/1` takes the DB row, so its
  # id is looked up fresh (cheap: only called while a delete confirmation is open).
  defp preset_affected(preset) do
    preset.id
    |> Presets.get_preset!()
    |> Presets.preset_deletion_effects()
    |> Enum.map(&%{label: &1, count: 1})
  end

  # `DR-55`'s one-line criteria summary, e.g. "Planned, invited, accepted · certain,
  # likely · any want tier · any age · any group" — built from the fixed display
  # orders above (never the `MapSet`'s own order) and capitalised only on its very
  # first character (a group name later in the string must never be re-cased).
  defp criteria_summary(preset, groups) do
    [
      ordered_criterion_summary(preset.invitation_statuses, @status_order, "any status"),
      ordered_criterion_summary(preset.certainties, @certainty_order, "any certainty"),
      ordered_criterion_summary(preset.want_tiers, @want_tier_order, "any want tier"),
      ordered_criterion_summary(preset.age_categories, @age_category_order, "any age"),
      group_criterion_summary(preset.group_ids, groups)
    ]
    |> Enum.join(" · ")
    |> capitalize_first()
  end

  defp ordered_criterion_summary(values, order, any_label) do
    case Enum.filter(order, &MapSet.member?(values, &1)) do
      [] -> any_label
      present -> present |> Enum.map(&to_string/1) |> Enum.join(", ")
    end
  end

  defp group_criterion_summary(group_ids, groups) do
    case Enum.filter(groups, &MapSet.member?(group_ids, &1.id)) do
      [] -> "any group"
      present -> present |> Enum.map(& &1.name) |> Enum.join(", ")
    end
  end

  defp capitalize_first(<<first::utf8, rest::binary>>), do: String.upcase(<<first::utf8>>) <> rest
  defp capitalize_first(other), do: other

  # Mirrors `WeddingPlannerWeb.OfferLive`'s own private helper (see its moduledoc for
  # why `<.button type="button">` cannot be used for Cancel here: its `:rest` global
  # attrs do not include `type`, so it would silently submit the enclosing form).
  defp secondary_button_class do
    "inline-flex min-h-11 items-center justify-center gap-2 rounded-field px-4 text-sm font-semibold " <>
      "cursor-pointer transition-all duration-150 ease-out active:scale-[0.98] " <>
      "focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-accent focus-visible:ring-offset-2 focus-visible:ring-offset-paper " <>
      "disabled:cursor-not-allowed disabled:opacity-50 disabled:active:scale-100 " <>
      "bg-transparent text-ink border border-line-strong hover:bg-surface active:bg-line"
  end

  # -- render -------------------------------------------------------------------------------

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_scope={@current_scope} width="wide">
      <.header>
        Headcount
        <:actions>
          <.export_link kind="headcount" time_zone={@time_zone} />
        </:actions>
      </.header>

      <p :if={@events == []} id="headcount-no-events" class="text-sm text-ink-soft">
        Add an event first —
        <.link navigate={~p"/events"} class="font-medium text-accent underline">
          go to Events
        </.link>
        .
      </p>

      <div
        :if={@events != []}
        class="relative overflow-x-auto rounded-field border border-line bg-surface-raised"
      >
        <div id="headcount-overview">
          <div class="grid border-b border-line bg-surface" style={grid_style(@overview.columns)}>
            <div class="sticky left-0 z-10 bg-surface px-3 py-2 text-xs font-semibold tracking-wide text-ink-soft uppercase">
              Event
            </div>
            <div
              :for={col <- @overview.columns}
              id={"headcount-col-#{col.id}"}
              class="px-3 py-2 text-xs font-semibold text-ink-soft"
            >
              {col.label}
            </div>
          </div>

          <p
            :if={@overview.columns == []}
            id="headcount-no-columns"
            class="px-3 py-4 text-sm text-ink-faint"
          >
            No presets and no ad hoc filter yet — build one below.
          </p>

          <div
            :for={row <- @overview.rows}
            id={"headcount-row-#{row.id}"}
            class="grid border-b border-line last:border-b-0"
            style={grid_style(@overview.columns)}
          >
            <div class="sticky left-0 z-10 bg-surface-raised px-3 py-2 text-sm font-medium text-ink">
              {row.label}
            </div>
            <div :for={col <- @overview.columns} class="p-1.5">
              <.headcount_cell
                id={"headcount-cell-#{row.id}-#{col.id}"}
                cell={Map.fetch!(row.cells, col.id)}
              />
            </div>
          </div>
        </div>
      </div>

      <p :if={@presets == []} id="headcount-no-presets" class="mt-3 text-sm text-ink-faint">
        There are no presets yet.
      </p>

      <section class="mt-8">
        <h2 class="text-sm font-semibold tracking-wide text-ink-soft uppercase">Ad hoc filter</h2>
        <p class="mt-1 text-xs text-ink-faint">
          Not saved anywhere — per-view only, until you save it as a preset.
        </p>

        <form
          id="adhoc-filter-form"
          phx-change="adhoc_filter"
          class="mt-3 grid grid-cols-1 gap-4 sm:grid-cols-2 lg:grid-cols-5"
        >
          <.adhoc_checkbox_group
            legend="Invitation status"
            field="invitation_statuses"
            options={@status_options}
            selected={@adhoc_params["invitation_statuses"]}
          />
          <.adhoc_checkbox_group
            legend="Effective certainty"
            field="certainties"
            options={@certainty_options}
            selected={@adhoc_params["certainties"]}
          />
          <.adhoc_checkbox_group
            legend="Want tier"
            field="want_tiers"
            options={@want_tier_options}
            selected={@adhoc_params["want_tiers"]}
          />
          <.adhoc_checkbox_group
            legend="Age category"
            field="age_categories"
            options={@age_category_options}
            selected={@adhoc_params["age_categories"]}
          />
          <.adhoc_checkbox_group
            legend="Groups"
            field="group_ids"
            options={Enum.map(@groups, &{&1.name, to_string(&1.id)})}
            selected={@adhoc_params["group_ids"]}
          />
        </form>

        <div :if={@adhoc_preset} class="mt-4 flex flex-wrap items-end gap-4">
          <button
            type="button"
            id="adhoc-filter-clear"
            phx-click="adhoc_clear"
            class="inline-flex min-h-11 items-center justify-center rounded-field border border-line-strong bg-surface-raised px-4 text-sm font-medium text-ink hover:bg-surface"
          >
            Clear
          </button>

          <.form
            for={@save_form}
            id="adhoc-save-form"
            phx-submit="adhoc_save"
            class="flex items-end gap-2"
          >
            <.input
              id="adhoc-save-name"
              field={@save_form[:name]}
              type="text"
              label="Save as preset"
              placeholder="Preset name"
            />
            <.button variant="primary">Save</.button>
          </.form>
        </div>
      </section>

      <section id="presets-section" class="mt-8">
        <div class="flex flex-wrap items-center justify-between gap-3">
          <div>
            <h2 class="text-sm font-semibold tracking-wide text-ink-soft uppercase">Presets</h2>
            <p class="mt-1 text-xs text-ink-faint">
              Rename, edit criteria (including groups), reorder or delete a custom
              preset. The three defaults, marked "Default (locked)", can be reordered
              but not renamed, edited or deleted.
            </p>
          </div>
          <.button variant="primary" id="preset-new" phx-click="new_preset">New preset</.button>
        </div>

        <.preset_editor
          :if={@editing_preset_id == :new}
          id="preset-form"
          form={@preset_form}
          status_options={@status_options}
          certainty_options={@certainty_options}
          want_tier_options={@want_tier_options}
          age_category_options={@age_category_options}
          groups={@groups}
        />

        <p :if={@presets == []} id="presets-empty" class="mt-4 text-sm text-ink-faint">
          There are no presets yet.
        </p>

        <ul :if={@presets != []} class="mt-4 space-y-3">
          <li
            :for={{preset, index} <- Enum.with_index(@presets)}
            id={"preset-#{preset.id}"}
            class="rounded-field border border-line bg-surface-raised p-4"
          >
            <div
              :if={@editing_preset_id != preset.id}
              class="flex flex-wrap items-start justify-between gap-3"
            >
              <div class="min-w-0">
                <div class="flex flex-wrap items-center gap-2">
                  <p class="font-medium text-ink">{preset.name}</p>
                  <.status_pill
                    :if={preset.role}
                    id={"preset-#{preset.id}-role"}
                    label="Default (locked)"
                    tone={:neutral}
                  />
                </div>
                <p id={"preset-#{preset.id}-summary"} class="mt-1 text-xs text-ink-faint">
                  {criteria_summary(preset, @groups)}
                </p>
              </div>

              <div class="flex shrink-0 items-center gap-2">
                <button
                  type="button"
                  id={"preset-up-#{preset.id}"}
                  phx-click="move_preset_up"
                  phx-value-id={preset.id}
                  disabled={index == 0}
                  aria-label={"Move #{preset.name} up"}
                  class="inline-flex min-h-11 min-w-11 items-center justify-center rounded-field border border-line-strong text-ink-soft transition hover:bg-surface disabled:cursor-not-allowed disabled:opacity-40"
                >
                  <.icon name="hero-chevron-up" />
                </button>
                <button
                  type="button"
                  id={"preset-down-#{preset.id}"}
                  phx-click="move_preset_down"
                  phx-value-id={preset.id}
                  disabled={index == length(@presets) - 1}
                  aria-label={"Move #{preset.name} down"}
                  class="inline-flex min-h-11 min-w-11 items-center justify-center rounded-field border border-line-strong text-ink-soft transition hover:bg-surface disabled:cursor-not-allowed disabled:opacity-40"
                >
                  <.icon name="hero-chevron-down" />
                </button>
                <.button
                  :if={is_nil(preset.role)}
                  id={"preset-edit-#{preset.id}"}
                  phx-click="edit_preset"
                  phx-value-id={preset.id}
                >
                  Edit
                </.button>
                <.button
                  :if={is_nil(preset.role)}
                  variant="destructive"
                  id={"preset-delete-#{preset.id}"}
                  phx-click="confirm_delete_preset"
                  phx-value-id={preset.id}
                >
                  Delete
                </.button>
              </div>
            </div>

            <.preset_editor
              :if={@editing_preset_id == preset.id}
              id="preset-form"
              form={@preset_form}
              status_options={@status_options}
              certainty_options={@certainty_options}
              want_tier_options={@want_tier_options}
              age_category_options={@age_category_options}
              groups={@groups}
            />

            <.destructive_confirm
              :if={@confirming_delete_preset_id == preset.id}
              id={"preset-delete-confirm-#{preset.id}"}
              title={"Delete '#{preset.name}'?"}
              body="This cannot be undone."
              affected={preset_affected(preset)}
              confirm="delete_preset_confirmed"
              confirm_value={preset.id}
              cancel="cancel_delete_preset"
            />

            <details id={"preset-history-#{preset.id}"} class="mt-3 text-sm">
              <summary class="cursor-pointer text-ink-soft hover:text-ink">History</summary>
              <div class="mt-2">
                <.entity_history
                  id={"preset-#{preset.id}-history"}
                  entity={{:headcount_preset, preset.id}}
                  entries={@preset_histories[preset.id] || []}
                  time_zone={@time_zone}
                />
              </div>
            </details>
          </li>
        </ul>
      </section>

      <WeddingPlannerWeb.Live.TimeZoneHook.probe id="headcount-time-zone-probe" />
    </Layouts.app>
    """
  end

  attr :id, :string, required: true
  attr :form, :any, required: true
  attr :status_options, :list, required: true
  attr :certainty_options, :list, required: true
  attr :want_tier_options, :list, required: true
  attr :age_category_options, :list, required: true
  attr :groups, :list, required: true

  defp preset_editor(assigns) do
    ~H"""
    <.form
      for={@form}
      id={@id}
      phx-change="validate_preset"
      phx-submit="save_preset"
      class="mt-4 space-y-4 rounded-field border border-line-strong bg-surface p-4"
    >
      <.input field={@form[:name]} type="text" label="Name" id="preset-form-name" />

      <div class="grid grid-cols-1 gap-4 sm:grid-cols-2 lg:grid-cols-5">
        <.preset_checkbox_group
          legend="Invitation status"
          field="invitation_statuses"
          options={@status_options}
          selected={form_selected_strings(@form, :invitation_statuses)}
        />
        <.preset_checkbox_group
          legend="Effective certainty"
          field="certainties"
          options={@certainty_options}
          selected={form_selected_strings(@form, :certainties)}
        />
        <.preset_checkbox_group
          legend="Want tier"
          field="want_tiers"
          options={@want_tier_options}
          selected={form_selected_strings(@form, :want_tiers)}
        />
        <.preset_checkbox_group
          legend="Age category"
          field="age_categories"
          options={@age_category_options}
          selected={form_selected_strings(@form, :age_categories)}
        />
        <.preset_checkbox_group
          legend="Groups"
          field="group_ids"
          options={Enum.map(@groups, &{&1.name, to_string(&1.id)})}
          selected={form_selected_strings(@form, :group_ids)}
        />
      </div>

      <div class="flex flex-wrap items-center gap-2">
        <.button variant="primary" id="preset-form-submit">Save</.button>
        <button
          type="button"
          id="preset-form-cancel"
          phx-click="cancel_preset_edit"
          class={secondary_button_class()}
        >
          Cancel
        </button>
      </div>
    </.form>
    """
  end

  attr :legend, :string, required: true
  attr :field, :string, required: true
  attr :options, :list, required: true
  attr :selected, :list, required: true

  defp preset_checkbox_group(assigns) do
    ~H"""
    <fieldset
      id={"preset-form-#{@field}"}
      class="rounded-field border border-line bg-surface-raised p-3"
    >
      <legend class="px-1 text-xs font-semibold tracking-wide text-ink-soft uppercase">
        {@legend}
      </legend>
      <input type="hidden" id={"preset-form-#{@field}-empty"} name={"preset[#{@field}][]"} value="" />
      <label
        :for={{label, value} <- @options}
        class="flex min-h-8 cursor-pointer items-center gap-2 text-sm text-ink"
      >
        <input
          type="checkbox"
          id={"preset-form-#{@field}-#{value}"}
          name={"preset[#{@field}][]"}
          value={value}
          checked={value in @selected}
          class="size-4 rounded border-line-strong accent-accent focus:outline-none focus:ring-2 focus:ring-accent"
        />
        {label}
      </label>
      <p :if={@options == []} class="text-xs text-ink-faint">None yet.</p>
    </fieldset>
    """
  end

  attr :legend, :string, required: true
  attr :field, :string, required: true
  attr :options, :list, required: true
  attr :selected, :list, required: true

  defp adhoc_checkbox_group(assigns) do
    ~H"""
    <fieldset id={"adhoc-#{@field}"} class="rounded-field border border-line bg-surface-raised p-3">
      <legend class="px-1 text-xs font-semibold tracking-wide text-ink-soft uppercase">
        {@legend}
      </legend>
      <input type="hidden" id={"adhoc-#{@field}-empty"} name={"adhoc[#{@field}][]"} value="" />
      <label
        :for={{label, value} <- @options}
        class="flex min-h-8 cursor-pointer items-center gap-2 text-sm text-ink"
      >
        <input
          type="checkbox"
          id={"adhoc-#{@field}-#{value}"}
          name={"adhoc[#{@field}][]"}
          value={value}
          checked={value in @selected}
          class="size-4 rounded border-line-strong accent-accent focus:outline-none focus:ring-2 focus:ring-accent"
        />
        {label}
      </label>
      <p :if={@options == []} class="text-xs text-ink-faint">None yet.</p>
    </fieldset>
    """
  end

  attr :id, :string, required: true
  attr :cell, :map, required: true

  defp headcount_cell(assigns) do
    ~H"""
    <details id={@id} class="rounded-field">
      <summary class="tabular-nums cursor-pointer list-none rounded-field px-2 py-1 text-sm font-medium text-ink hover:bg-surface focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-accent">
        {@cell.total_text}
      </summary>
      <div class="mt-2 space-y-2 px-1">
        <.formula
          id={"#{@id}-formula"}
          total_label={@cell.formula.total_label}
          total={@cell.formula.total}
          steps={@cell.formula.steps}
          open={true}
        />
        <div id={"#{@id}-names"}>
          <p class="text-xs font-medium tracking-wide text-ink-soft uppercase">Who is counted</p>
          <ul :if={@cell.names != []} class="mt-1 space-y-0.5 text-sm text-ink">
            <li :for={name <- @cell.names}>{name}</li>
          </ul>
          <p :if={@cell.names == []} class="mt-1 text-sm text-ink-faint">Nobody</p>
        </div>
      </div>
    </details>
    """
  end

  defp grid_style(columns) do
    count = length(columns)
    min_width = 200 + count * 220

    "display: grid; grid-template-columns: 200px repeat(#{count}, minmax(220px, 1fr)); min-width: #{min_width}px;"
  end
end
