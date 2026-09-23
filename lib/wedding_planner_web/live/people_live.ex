defmodule WeddingPlannerWeb.Live.PeopleLive do
  @moduledoc """
  The people-management screen (task 27; `docs/modules/guests-and-events.md` `PER-01`
  through `PER-07`) — flat/grouped views, inline editing of every `PER-02` field, bulk
  entry (paste + quick-add), bulk actions and group management, on top of task 26's
  `WeddingPlanner.Guests` context. `.claude/design/ui-decisions.md` §6 is the locked
  design this implements.

  ## URL is the source of truth for view/sort/filters (`DR-26` Q7–Q9)

  `?view=flat|grouped`, `?sort=`/`?dir=`, and `?q=`/`?group=`/`?age=`/`?want=`/
  `?certainty=` are all query params, applied in `handle_params/3`. Every control that
  changes one of them is a `push_patch`, never a plain assign — this is what lets a
  reload and the activity log's group anchor (`/people?view=grouped#group-<id>`) land on
  the right state.

  ## One stream, two row kinds

  `@streams.rows` holds a single, explicitly-ordered list built in `refresh/1`: in flat
  view, one row per person (`kind: :person`); in grouped view, a `kind: :group_header`
  row followed by that group's member `:person` rows, group by group in
  `WeddingPlanner.Guests.list_groups/0` order, then an `"Ungrouped"` header and its
  members last — built explicitly (never relying on encounter order, the v4 prototype
  bug this design record calls out). Every assign that changes what a row renders
  (selection, the open notes row, either delete confirmation, group history open,
  inline-edit errors) is baked into the row map itself, so any change to it re-runs
  `refresh/1` (full refetch, `reset: true`) rather than trying to hand-patch one stream
  entry — cheap at `NFR-33`'s "≤ ~150 persons" scale, and far less error-prone than
  tracking which assign affects which row.

  ## Inline edits: no forms, direct bindings, commit on blur or change

  Every inline field (first/last name, notes, and the group/age/want/certainty selects)
  is a bare `<input>`/`<select>`/`<textarea>` with `phx-blur` (text/notes) or `phx-change`
  (selects) bound directly to it — no `<form>` wrapper at all, so "no nested `<form>`
  elements" never becomes a question for these. Each carries `phx-value-id` (the person
  or group id) and `phx-value-field` (which `PER-02`/group field), landing in one shared
  `"update_person_field"`/`"update_group_field"` handler that calls
  `WeddingPlanner.Guests.update_person/3` or `update_group/3` — the context does the
  actual "did this field change" diffing for `XC-10` logging, so typing without blurring
  never reaches the server at all (never mind logs one entry per keystroke).

  The three genuinely multi-field, submit-driven forms — quick-add, "+ New group", and
  the toolbar's filter bar — are real `to_form/2`-backed `<.form>`s, siblings of the row
  stream, not nested inside it.

  ## Live updates (`XC-01`, `DR-21`)

  Subscribes to `:person`, `:group` and `:activity_entry` (for any open group-history
  panel). Every broadcast just calls `refresh/1` — silent, no highlight, badge or
  "updated" notice of any kind (`DR-21`/`XC-02`).
  """
  use WeddingPlannerWeb, :live_view

  import WeddingPlannerWeb.ActivityComponents, only: [entity_history: 1]

  alias WeddingPlanner.Guests
  alias WeddingPlanner.Guests.Group
  alias WeddingPlanner.Guests.PasteParser
  alias WeddingPlanner.Guests.Person
  alias WeddingPlanner.Log.Query, as: LogQuery
  alias WeddingPlanner.Realtime

  on_mount {WeddingPlannerWeb.Live.TimeZoneHook, :default}

  @default_entry_defaults %{
    group_id: nil,
    age_category: :adult,
    want_tier: :yes,
    certainty: :likely
  }

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket) do
      Realtime.subscribe(:person)
      Realtime.subscribe(:group)
      Realtime.subscribe(:activity_entry)
    end

    socket =
      socket
      # Row maps already carry their final DOM id ("person-<id>" / "group-<id>" /
      # "group-ungrouped") — the group anchor `/people?view=grouped#group-<id>` (built by
      # `WeddingPlanner.Guests.resolve_group_log_entity/1`) needs that id literally, not
      # LiveView's default "rows-<id>" stream prefix.
      |> stream_configure(:rows, dom_id: & &1.id)
      |> assign(:page_title, "People")
      |> assign(:selected_ids, MapSet.new())
      |> assign(:notes_open_ids, MapSet.new())
      |> assign(:confirming_delete_id, nil)
      |> assign(:confirming_group_delete_id, nil)
      |> assign(:confirming_bulk_delete, false)
      |> assign(:group_history_open_ids, MapSet.new())
      |> assign(:row_errors, %{})
      |> assign(:group_errors, %{})
      |> assign(:paste_open, false)
      |> assign(:paste_text, "")
      |> assign(:paste_preview, [])
      |> assign(:new_group_open, false)
      |> assign(:new_group_form, to_form(Guests.change_group(%Group{}), as: "group"))
      |> assign(:entry_defaults, @default_entry_defaults)
      |> assign(:quick_add_form, quick_add_form(@default_entry_defaults))

    {:ok, socket}
  end

  @impl true
  def handle_params(params, _uri, socket) do
    view = if params["view"] == "grouped", do: "grouped", else: "flat"
    sort = parse_sort(params["sort"], params["dir"])
    filters = parse_filters(params)

    socket =
      socket
      |> assign(:view, view)
      |> assign(:sort, sort)
      |> assign(:filters, filters)
      |> assign(:filter_form, filter_form(filters))
      |> refresh()

    {:noreply, socket}
  end

  # -- toolbar: view/sort/filters (push_patch, handled in handle_params) --------------

  @impl true
  def handle_event("filter", %{"filter" => params}, socket) do
    changes = %{
      "q" => params["q"],
      "group" => params["group"],
      "age" => params["age"],
      "want" => params["want"],
      "certainty" => params["certainty"]
    }

    {:noreply, push_patch(socket, to: people_path(socket.assigns, changes))}
  end

  # -- selection -----------------------------------------------------------------------

  def handle_event("toggle_select", %{"id" => id}, socket) do
    id = String.to_integer(id)
    selected = toggle_member(socket.assigns.selected_ids, id)
    {:noreply, socket |> assign(:selected_ids, selected) |> refresh()}
  end

  def handle_event("toggle_select_group", %{"group" => key}, socket) do
    member_ids = group_member_ids(socket, key)
    current = socket.assigns.selected_ids
    all_selected? = member_ids != [] and Enum.all?(member_ids, &MapSet.member?(current, &1))

    selected =
      Enum.reduce(member_ids, current, fn id, acc ->
        if all_selected?, do: MapSet.delete(acc, id), else: MapSet.put(acc, id)
      end)

    {:noreply, socket |> assign(:selected_ids, selected) |> refresh()}
  end

  # -- notes -----------------------------------------------------------------------------

  def handle_event("toggle_notes", %{"id" => id}, socket) do
    id = String.to_integer(id)
    ids = toggle_member(socket.assigns.notes_open_ids, id)
    {:noreply, socket |> assign(:notes_open_ids, ids) |> refresh()}
  end

  # -- inline person edit ---------------------------------------------------------------

  def handle_event(
        "update_person_field",
        %{"id" => id, "field" => field, "value" => value},
        socket
      ) do
    person = Guests.get_person!(id)
    scope = socket.assigns.current_scope

    case Guests.update_person(scope, person, person_field_attrs(field, value)) do
      {:ok, _updated} ->
        {:noreply, socket |> clear_row_error(person.id) |> refresh()}

      {:error, changeset} ->
        {:noreply, socket |> put_row_error(person.id, changeset) |> refresh()}
    end
  end

  # -- single-person delete (XC-40) -------------------------------------------------------

  def handle_event("confirm_delete", %{"id" => id}, socket) do
    {:noreply, socket |> assign(:confirming_delete_id, String.to_integer(id)) |> refresh()}
  end

  def handle_event("cancel_delete", _params, socket) do
    {:noreply, socket |> assign(:confirming_delete_id, nil) |> refresh()}
  end

  def handle_event("delete_confirmed", %{"id" => id}, socket) do
    scope = socket.assigns.current_scope
    person = Guests.get_person!(id)
    {:ok, _} = Guests.delete_person(scope, person)

    id_int = String.to_integer(id)

    socket =
      socket
      |> assign(:confirming_delete_id, nil)
      |> assign(:selected_ids, MapSet.delete(socket.assigns.selected_ids, id_int))
      |> refresh()

    {:noreply, socket}
  end

  # -- quick add (PER-02, DR-26 Q6) -----------------------------------------------------

  def handle_event("quick_add_validate", %{"quick_add" => params}, socket) do
    changeset = %Person{} |> Guests.change_person(params) |> Map.put(:action, :validate)
    {:noreply, assign(socket, :quick_add_form, to_form(changeset, as: "quick_add"))}
  end

  def handle_event("quick_add_submit", %{"quick_add" => params}, socket) do
    scope = socket.assigns.current_scope

    case Guests.create_person(scope, params) do
      {:ok, _person} ->
        defaults = entry_defaults_from_params(params)

        socket =
          socket
          |> assign(:entry_defaults, defaults)
          |> assign(:quick_add_form, quick_add_form(defaults))
          |> refresh()

        {:noreply, socket}

      {:error, changeset} ->
        {:noreply, assign(socket, :quick_add_form, to_form(changeset, as: "quick_add"))}
    end
  end

  # -- paste a list (PER-04, DR-26 Q5, Q6) ----------------------------------------------

  def handle_event("toggle_paste", _params, socket) do
    {:noreply, assign(socket, :paste_open, !socket.assigns.paste_open)}
  end

  def handle_event("paste_preview", params, socket) do
    text = params["text"] || ""
    parsed = PasteParser.parse(text)
    {:noreply, socket |> assign(:paste_text, text) |> assign(:paste_preview, parsed)}
  end

  def handle_event("paste_submit", params, socket) do
    parsed = PasteParser.parse(params["text"] || "")
    name_maps = for {:ok, entry} <- parsed, do: entry
    invalid_count = length(parsed) - length(name_maps)

    case name_maps do
      [] ->
        {:noreply, put_flash(socket, :error, "No valid names to add.")}

      _ ->
        scope = socket.assigns.current_scope
        shared_attrs = paste_shared_attrs(params)
        {:ok, added} = Guests.bulk_create_persons(scope, name_maps, shared_attrs)
        defaults = entry_defaults_from_params(params)

        socket =
          socket
          |> put_flash(:info, paste_flash_message(length(added), invalid_count))
          |> assign(:entry_defaults, defaults)
          |> assign(:quick_add_form, quick_add_form(defaults))
          |> assign(:paste_text, "")
          |> assign(:paste_preview, [])
          |> assign(:paste_open, false)
          |> refresh()

        {:noreply, socket}
    end
  end

  # -- new group (PER-03, DR-26 Q10) ------------------------------------------------------

  def handle_event("toggle_new_group", _params, socket) do
    {:noreply, assign(socket, :new_group_open, !socket.assigns.new_group_open)}
  end

  def handle_event("new_group_validate", %{"group" => params}, socket) do
    changeset = %Group{} |> Guests.change_group(params) |> Map.put(:action, :validate)
    {:noreply, assign(socket, :new_group_form, to_form(changeset, as: "group"))}
  end

  def handle_event("new_group_submit", %{"group" => params}, socket) do
    scope = socket.assigns.current_scope

    case Guests.create_group(scope, params) do
      {:ok, _group} ->
        socket =
          socket
          |> assign(:new_group_open, false)
          |> assign(:new_group_form, to_form(Guests.change_group(%Group{}), as: "group"))
          |> refresh()

        {:noreply, socket}

      {:error, changeset} ->
        {:noreply, assign(socket, :new_group_form, to_form(changeset, as: "group"))}
    end
  end

  # -- group inline edit / management (DR-26 Q10) -----------------------------------------

  def handle_event(
        "update_group_field",
        %{"id" => id, "field" => field, "value" => value},
        socket
      ) do
    group = Guests.get_group!(id)
    scope = socket.assigns.current_scope

    case Guests.update_group(scope, group, %{field => value}) do
      {:ok, _updated} ->
        {:noreply, socket |> clear_group_error(group.id) |> refresh()}

      {:error, changeset} ->
        {:noreply, socket |> put_group_error(group.id, changeset) |> refresh()}
    end
  end

  def handle_event("confirm_group_delete", %{"id" => id}, socket) do
    {:noreply, socket |> assign(:confirming_group_delete_id, String.to_integer(id)) |> refresh()}
  end

  def handle_event("cancel_group_delete", _params, socket) do
    {:noreply, socket |> assign(:confirming_group_delete_id, nil) |> refresh()}
  end

  def handle_event("group_delete_confirmed", %{"id" => id}, socket) do
    scope = socket.assigns.current_scope
    group = Guests.get_group!(id)
    {:ok, _} = Guests.delete_group(scope, group)

    {:noreply, socket |> assign(:confirming_group_delete_id, nil) |> refresh()}
  end

  def handle_event("toggle_group_history", %{"id" => id}, socket) do
    id = String.to_integer(id)
    ids = toggle_member(socket.assigns.group_history_open_ids, id)
    {:noreply, socket |> assign(:group_history_open_ids, ids) |> refresh()}
  end

  # -- bulk bar (PER-04, PER-07) ---------------------------------------------------------

  def handle_event("bulk_set_want_tier", %{"tier" => tier}, socket) do
    apply_bulk_update(socket, :want_tier, parse_want(tier))
  end

  def handle_event("bulk_set_certainty", %{"certainty" => certainty}, socket) do
    apply_bulk_update(socket, :certainty, parse_certainty(certainty))
  end

  def handle_event("confirm_bulk_delete", _params, socket) do
    {:noreply, assign(socket, :confirming_bulk_delete, true)}
  end

  def handle_event("cancel_bulk_delete", _params, socket) do
    {:noreply, assign(socket, :confirming_bulk_delete, false)}
  end

  def handle_event("bulk_delete_confirmed", _params, socket) do
    scope = socket.assigns.current_scope
    persons = selected_persons(socket)
    {:ok, _} = Guests.bulk_delete_persons(scope, persons)

    socket =
      socket
      |> assign(:selected_ids, MapSet.new())
      |> assign(:confirming_bulk_delete, false)
      |> refresh()

    {:noreply, socket}
  end

  defp apply_bulk_update(socket, field, value) do
    scope = socket.assigns.current_scope
    persons = selected_persons(socket)
    {:ok, _} = Guests.bulk_update_persons(scope, persons, field, value)

    {:noreply, socket |> assign(:selected_ids, MapSet.new()) |> refresh()}
  end

  # -- live updates (XC-01, DR-21) --------------------------------------------------------

  @impl true
  def handle_info({Realtime, :person, _event}, socket), do: {:noreply, refresh(socket)}
  def handle_info({Realtime, :group, _event}, socket), do: {:noreply, refresh(socket)}

  def handle_info({Realtime, :activity_entry, {:created, _entry}}, socket) do
    if MapSet.size(socket.assigns.group_history_open_ids) > 0 do
      {:noreply, refresh(socket)}
    else
      {:noreply, socket}
    end
  end

  # -- data refresh ------------------------------------------------------------------------

  defp refresh(socket) do
    filters = socket.assigns.filters
    sort = socket.assigns.sort

    groups = Guests.list_groups()
    all_persons = Guests.list_persons(%{})
    persons = Guests.list_persons(%{sort: sort, filters: filters})

    selected_persons =
      Enum.filter(all_persons, &MapSet.member?(socket.assigns.selected_ids, &1.id))

    socket
    |> assign(:groups, groups)
    |> assign(:total_count, length(all_persons))
    |> assign(:shown_count, length(persons))
    |> assign(:selected_persons, selected_persons)
    |> stream(:rows, build_rows(socket, persons, groups), reset: true)
  end

  defp build_rows(socket, persons, groups) do
    case socket.assigns.view do
      "grouped" -> build_grouped_rows(socket, persons, groups)
      _ -> Enum.map(persons, &person_row(socket, &1))
    end
  end

  defp build_grouped_rows(socket, persons, groups) do
    group_rows =
      Enum.flat_map(groups, fn group ->
        members = Enum.filter(persons, &(&1.group_id == group.id))
        [group_header_row(socket, group, members) | Enum.map(members, &person_row(socket, &1))]
      end)

    ungrouped_members = Enum.filter(persons, &is_nil(&1.group_id))
    ungrouped_row = group_header_row(socket, nil, ungrouped_members)

    group_rows ++ [ungrouped_row | Enum.map(ungrouped_members, &person_row(socket, &1))]
  end

  defp person_row(socket, person) do
    %{
      id: "person-#{person.id}",
      kind: :person,
      person: person,
      selected?: MapSet.member?(socket.assigns.selected_ids, person.id),
      notes_open?: MapSet.member?(socket.assigns.notes_open_ids, person.id),
      confirming_delete?: socket.assigns.confirming_delete_id == person.id,
      errors: socket.assigns.row_errors |> Map.get(person.id) |> changeset_errors()
    }
  end

  defp group_header_row(socket, group, members) do
    history_open? =
      group != nil and MapSet.member?(socket.assigns.group_history_open_ids, group.id)

    %{
      id: (group && "group-#{group.id}") || "group-ungrouped",
      kind: :group_header,
      group: group,
      members: members,
      selected_all?:
        members != [] and Enum.all?(members, &MapSet.member?(socket.assigns.selected_ids, &1.id)),
      history_open?: history_open?,
      history_entries: if(history_open?, do: LogQuery.for_entity(:group, group.id), else: []),
      confirming_delete?: group != nil and socket.assigns.confirming_group_delete_id == group.id,
      errors:
        (group && socket.assigns.group_errors |> Map.get(group.id) |> changeset_errors()) || []
    }
  end

  defp group_member_ids(socket, "ungrouped") do
    socket.assigns.filters
    |> then(&Guests.list_persons(%{filters: &1}))
    |> Enum.filter(&is_nil(&1.group_id))
    |> Enum.map(& &1.id)
  end

  defp group_member_ids(socket, group_id_str) do
    group_id = String.to_integer(group_id_str)

    socket.assigns.filters
    |> then(&Guests.list_persons(%{filters: &1}))
    |> Enum.filter(&(&1.group_id == group_id))
    |> Enum.map(& &1.id)
  end

  defp selected_persons(socket) do
    ids = socket.assigns.selected_ids
    Guests.list_persons(%{}) |> Enum.filter(&MapSet.member?(ids, &1.id))
  end

  # -- helpers -----------------------------------------------------------------------------

  defp toggle_member(set, id) do
    if MapSet.member?(set, id), do: MapSet.delete(set, id), else: MapSet.put(set, id)
  end

  defp clear_row_error(socket, id),
    do: assign(socket, :row_errors, Map.delete(socket.assigns.row_errors, id))

  defp put_row_error(socket, id, cs),
    do: assign(socket, :row_errors, Map.put(socket.assigns.row_errors, id, cs))

  defp clear_group_error(socket, id),
    do: assign(socket, :group_errors, Map.delete(socket.assigns.group_errors, id))

  defp put_group_error(socket, id, cs),
    do: assign(socket, :group_errors, Map.put(socket.assigns.group_errors, id, cs))

  defp changeset_errors(nil), do: []

  defp changeset_errors(changeset) do
    changeset
    |> Ecto.Changeset.traverse_errors(fn {msg, opts} ->
      Enum.reduce(opts, msg, fn {key, value}, acc ->
        String.replace(acc, "%{#{key}}", to_string(value))
      end)
    end)
    |> Enum.flat_map(fn {_field, msgs} -> msgs end)
    |> Enum.uniq()
  end

  defp person_field_attrs("group_id", ""), do: %{"group_id" => nil}
  defp person_field_attrs(field, value), do: %{field => value}

  defp quick_add_form(defaults),
    do: to_form(Guests.change_person(%Person{}, entry_defaults_attrs(defaults)), as: "quick_add")

  defp entry_defaults_attrs(defaults) do
    %{
      "group_id" => defaults.group_id && to_string(defaults.group_id),
      "age_category" => Atom.to_string(defaults.age_category),
      "want_tier" => Atom.to_string(defaults.want_tier),
      "certainty" => Atom.to_string(defaults.certainty)
    }
  end

  defp entry_defaults_from_params(params) do
    %{
      group_id: parse_group_id(params["group_id"]),
      age_category: parse_age(params["age_category"]) || :adult,
      want_tier: parse_want(params["want_tier"]) || :yes,
      certainty: parse_certainty(params["certainty"]) || :likely
    }
  end

  # Atom-keyed, matching `WeddingPlanner.Guests.PasteParser.parse/1`'s atom-keyed name
  # maps — `bulk_create_persons/3` merges the two, and `Ecto.Changeset.cast/4` rejects a
  # mixed atom/string-keyed map.
  defp paste_shared_attrs(params) do
    %{}
    |> maybe_put(:group_id, blank_to_nil(params["group_id"]))
    |> maybe_put(:age_category, blank_to_nil(params["age_category"]))
    |> maybe_put(:want_tier, blank_to_nil(params["want_tier"]))
    |> maybe_put(:certainty, blank_to_nil(params["certainty"]))
  end

  defp paste_flash_message(added, 0), do: "Added #{added} #{pluralize(added)}."

  defp paste_flash_message(added, skipped) do
    "Added #{added} #{pluralize(added)}, #{skipped} #{pluralize_line(skipped)} skipped."
  end

  defp valid_paste_count(preview), do: Enum.count(preview, &match?({:ok, _}, &1))

  defp paste_summary([]), do: "Paste names above to preview."

  defp paste_summary(preview) do
    valid = valid_paste_count(preview)
    invalid = length(preview) - valid
    base = "Add #{valid} #{pluralize(valid)}"
    if invalid > 0, do: base <> " (#{invalid} #{pluralize_line(invalid)} skipped)", else: base
  end

  defp pluralize(1), do: "person"
  defp pluralize(_), do: "people"
  defp pluralize_line(1), do: "line"
  defp pluralize_line(_), do: "lines"

  defp bulk_delete_title(persons) do
    names = persons |> Enum.map(&Person.display_name/1) |> Enum.join(", ")
    "Delete #{length(persons)} #{pluralize(length(persons))}: #{names}?"
  end

  defp group_key(nil), do: "ungrouped"
  defp group_key(%Group{id: id}), do: to_string(id)

  defp age_label(:adult), do: "Adult"
  defp age_label(:child), do: "Child"

  defp want_label(:yes), do: "Yes"
  defp want_label(:maybe), do: "Maybe"
  defp want_label(:no), do: "No"
  defp want_label(:obligated), do: "Obligated"

  defp certainty_label(:certain), do: "Certain"
  defp certainty_label(:likely), do: "Likely"
  defp certainty_label(:uncertain), do: "Uncertain"

  # DR-16 semantic assignment (`.claude/design/ui-decisions.md` §2): want tier yes/maybe/
  # no/obligated -> good/warn/bad/info. Certainty has no assigned colour in that table, so
  # its select stays neutrally styled.
  defp want_tone(:yes), do: :good
  defp want_tone(:maybe), do: :warn
  defp want_tone(:no), do: :bad
  defp want_tone(:obligated), do: :info

  defp tone_class(:good), do: "text-good"
  defp tone_class(:warn), do: "text-warn"
  defp tone_class(:bad), do: "text-bad"
  defp tone_class(:info), do: "text-info"

  defp blank_to_nil(nil), do: nil
  defp blank_to_nil(""), do: nil
  defp blank_to_nil(value), do: value

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)

  defp parse_group_id(nil), do: nil
  defp parse_group_id(""), do: nil

  defp parse_group_id(str) do
    case Integer.parse(str) do
      {id, ""} -> id
      _ -> nil
    end
  end

  defp parse_age("adult"), do: :adult
  defp parse_age("child"), do: :child
  defp parse_age(_), do: nil

  defp parse_want("yes"), do: :yes
  defp parse_want("maybe"), do: :maybe
  defp parse_want("no"), do: :no
  defp parse_want("obligated"), do: :obligated
  defp parse_want(_), do: nil

  defp parse_certainty("certain"), do: :certain
  defp parse_certainty("likely"), do: :likely
  defp parse_certainty("uncertain"), do: :uncertain
  defp parse_certainty(_), do: nil

  @sort_labels %{
    first_name: "first_name",
    last_name: "last_name",
    group: "group",
    age_category: "age_category",
    want_tier: "want_tier",
    certainty: "certainty",
    name: "name"
  }

  defp parse_sort(attr_str, dir_str) do
    attr = normalize_sort_attr(attr_str)
    dir = if dir_str == "desc", do: :desc, else: :asc
    {attr, dir}
  end

  defp normalize_sort_attr("first_name"), do: :first_name
  defp normalize_sort_attr("last_name"), do: :last_name
  defp normalize_sort_attr("group"), do: :group
  defp normalize_sort_attr("age_category"), do: :age_category
  defp normalize_sort_attr("want_tier"), do: :want_tier
  defp normalize_sort_attr("certainty"), do: :certainty
  defp normalize_sort_attr(_), do: :name

  defp parse_filters(params) do
    %{}
    |> maybe_put(:text, blank_to_nil(params["q"]))
    |> maybe_put(:group_id, parse_group_filter(params["group"]))
    |> maybe_put(:age_category, parse_age(params["age"]))
    |> maybe_put(:want_tier, parse_want(params["want"]))
    |> maybe_put(:certainty, parse_certainty(params["certainty"]))
  end

  defp parse_group_filter("ungrouped"), do: :ungrouped
  defp parse_group_filter(nil), do: nil
  defp parse_group_filter(""), do: nil

  defp parse_group_filter(str) do
    case Integer.parse(str) do
      {id, ""} -> id
      _ -> nil
    end
  end

  defp filter_form(filters) do
    to_form(
      %{
        "q" => Map.get(filters, :text) || "",
        "group" => group_filter_param(Map.get(filters, :group_id)),
        "age" => filter_param(Map.get(filters, :age_category)),
        "want" => filter_param(Map.get(filters, :want_tier)),
        "certainty" => filter_param(Map.get(filters, :certainty))
      },
      as: "filter"
    )
  end

  defp group_filter_param(:ungrouped), do: "ungrouped"
  defp group_filter_param(nil), do: ""
  defp group_filter_param(id), do: to_string(id)

  defp filter_param(nil), do: ""
  defp filter_param(atom), do: Atom.to_string(atom)

  defp sort_change(assigns, attr) do
    {current_attr, current_dir} = assigns.sort
    next_dir = if current_attr == attr and current_dir == :asc, do: "desc", else: "asc"
    %{"sort" => Map.fetch!(@sort_labels, attr), "dir" => next_dir}
  end

  defp sort_arrow(assigns, attr) do
    case assigns.sort do
      {^attr, :asc} -> " ↑"
      {^attr, :desc} -> " ↓"
      _ -> ""
    end
  end

  defp query_params(assigns, changes) do
    {sort_attr, sort_dir} = assigns.sort

    %{
      "view" => assigns.view,
      "sort" => Map.fetch!(@sort_labels, sort_attr),
      "dir" => Atom.to_string(sort_dir),
      "q" => Map.get(assigns.filters, :text),
      "group" => group_filter_param(Map.get(assigns.filters, :group_id)),
      "age" => filter_param(Map.get(assigns.filters, :age_category)),
      "want" => filter_param(Map.get(assigns.filters, :want_tier)),
      "certainty" => filter_param(Map.get(assigns.filters, :certainty))
    }
    |> Map.merge(changes)
    |> Enum.reject(fn {_k, v} -> v in [nil, ""] end)
    |> Map.new()
  end

  defp people_path(assigns, changes), do: ~p"/people?#{query_params(assigns, changes)}"

  # -- render --------------------------------------------------------------------------

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_scope={@current_scope} width="wide">
      <WeddingPlannerWeb.Live.TimeZoneHook.probe id="people-time-zone-probe" />

      <.header>
        People
        <:actions>
          <.button id="people-new-group-toggle" phx-click="toggle_new_group">
            + New group
          </.button>
          <.button id="people-paste-toggle" phx-click="toggle_paste">
            {if @paste_open, do: "Hide paste panel", else: "Paste a list"}
          </.button>
        </:actions>
      </.header>

      <div
        :if={@new_group_open}
        id="new-group-form-panel"
        class="rounded-field border border-line bg-surface-raised p-3"
      >
        <.form
          for={@new_group_form}
          id="new-group-form"
          phx-submit="new_group_submit"
          phx-change="new_group_validate"
          class="flex flex-wrap items-end gap-2"
        >
          <.input field={@new_group_form[:name]} type="text" label="Group name" id="new-group-name" />
          <.input
            field={@new_group_form[:type_label]}
            type="text"
            label="Type (optional)"
            id="new-group-type-label"
            list="group-type-suggestions"
          />
          <.button variant="primary" id="new-group-submit">Create group</.button>
        </.form>
      </div>

      <datalist id="group-type-suggestions">
        <option value="household" />
        <option value="circle" />
        <option value="family" />
        <option value="friends" />
        <option value="colleagues" />
      </datalist>

      <div
        :if={@paste_open}
        id="paste-panel"
        class="rounded-field border border-line bg-surface-raised p-3"
      >
        <form id="paste-form" phx-change="paste_preview" phx-submit="paste_submit" class="space-y-3">
          <.input
            type="textarea"
            name="text"
            id="paste-text"
            label="Paste names, one per line"
            value={@paste_text}
            rows="6"
          />

          <div class="flex flex-wrap gap-2">
            <.input
              type="select"
              name="group_id"
              id="paste-group"
              label="Group"
              prompt="No group"
              options={Enum.map(@groups, &{&1.name, &1.id})}
              value={@entry_defaults.group_id}
            />
            <.input
              type="select"
              name="age_category"
              id="paste-age"
              label="Age"
              options={Enum.map(Person.age_categories(), &{age_label(&1), &1})}
              value={@entry_defaults.age_category}
            />
            <.input
              type="select"
              name="want_tier"
              id="paste-want"
              label="Want tier"
              options={Enum.map(Person.want_tiers(), &{want_label(&1), &1})}
              value={@entry_defaults.want_tier}
            />
            <.input
              type="select"
              name="certainty"
              id="paste-certainty"
              label="Certainty"
              options={Enum.map(Person.certainties(), &{certainty_label(&1), &1})}
              value={@entry_defaults.certainty}
            />
          </div>

          <div id="paste-preview" class="text-sm">
            <p id="paste-preview-count" class="font-medium text-ink">
              {paste_summary(@paste_preview)}
            </p>
            <ul :if={@paste_preview != []} class="mt-1 space-y-0.5 text-ink-soft">
              <li
                :for={{entry, idx} <- Enum.with_index(@paste_preview)}
                id={"paste-preview-line-#{idx}"}
              >
                <%= case entry do %>
                  <% {:ok, %{first_name: f, last_name: l}} -> %>
                    {[f, l] |> Enum.reject(&is_nil/1) |> Enum.join(" ")}
                  <% {:error, line, reason} -> %>
                    <span class="text-bad">{line} &mdash; {reason}</span>
                <% end %>
              </li>
            </ul>
          </div>

          <.button
            variant="primary"
            id="paste-submit"
            disabled={valid_paste_count(@paste_preview) == 0}
          >
            Add {valid_paste_count(@paste_preview)} {pluralize(valid_paste_count(@paste_preview))}
          </.button>
        </form>
      </div>

      <.form
        for={@quick_add_form}
        id="quick-add-form"
        phx-change="quick_add_validate"
        phx-submit="quick_add_submit"
        class="flex flex-wrap items-end gap-2 rounded-field border border-line bg-surface-raised p-3"
      >
        <.input
          field={@quick_add_form[:first_name]}
          type="text"
          label="First name"
          id="quick-add-first-name"
        />
        <.input
          field={@quick_add_form[:last_name]}
          type="text"
          label="Last name"
          id="quick-add-last-name"
        />
        <.input
          field={@quick_add_form[:group_id]}
          type="select"
          label="Group"
          prompt="No group"
          options={Enum.map(@groups, &{&1.name, &1.id})}
          id="quick-add-group"
        />
        <.input
          field={@quick_add_form[:age_category]}
          type="select"
          label="Age"
          options={Enum.map(Person.age_categories(), &{age_label(&1), &1})}
          id="quick-add-age"
        />
        <.input
          field={@quick_add_form[:want_tier]}
          type="select"
          label="Want tier"
          options={Enum.map(Person.want_tiers(), &{want_label(&1), &1})}
          id="quick-add-want"
        />
        <.input
          field={@quick_add_form[:certainty]}
          type="select"
          label="Certainty"
          options={Enum.map(Person.certainties(), &{certainty_label(&1), &1})}
          id="quick-add-certainty"
        />
        <.button variant="primary" id="quick-add-submit">Add</.button>
      </.form>

      <div class="flex flex-wrap items-center justify-between gap-3">
        <div class="flex flex-wrap items-center gap-2">
          <.link
            patch={people_path(assigns, %{"view" => "flat"})}
            id="people-view-flat"
            class={[
              "rounded-chip px-3 py-1.5 text-sm font-medium",
              @view == "flat" && "bg-accent text-white",
              @view != "flat" && "text-ink-soft hover:bg-surface"
            ]}
          >
            Flat
          </.link>
          <.link
            patch={people_path(assigns, %{"view" => "grouped"})}
            id="people-view-grouped"
            class={[
              "rounded-chip px-3 py-1.5 text-sm font-medium",
              @view == "grouped" && "bg-accent text-white",
              @view != "grouped" && "text-ink-soft hover:bg-surface"
            ]}
          >
            Grouped
          </.link>
        </div>
        <p id="people-count" class="text-sm text-ink-soft">{@shown_count} of {@total_count} shown</p>
      </div>

      <.form
        for={@filter_form}
        id="people-filters"
        phx-change="filter"
        class="flex flex-wrap items-end gap-3"
      >
        <.input
          field={@filter_form[:q]}
          type="text"
          label="Search"
          placeholder="Name or notes"
          id="people-filter-q"
        />
        <.input
          field={@filter_form[:group]}
          type="select"
          label="Group"
          prompt="All groups"
          options={[{"Ungrouped", "ungrouped"} | Enum.map(@groups, &{&1.name, &1.id})]}
          id="people-filter-group"
        />
        <.input
          field={@filter_form[:age]}
          type="select"
          label="Age"
          prompt="All ages"
          options={[{"Adult", "adult"}, {"Child", "child"}]}
          id="people-filter-age"
        />
        <.input
          field={@filter_form[:want]}
          type="select"
          label="Want tier"
          prompt="All tiers"
          options={Enum.map(Person.want_tiers(), &{want_label(&1), &1})}
          id="people-filter-want"
        />
        <.input
          field={@filter_form[:certainty]}
          type="select"
          label="Certainty"
          prompt="All"
          options={Enum.map(Person.certainties(), &{certainty_label(&1), &1})}
          id="people-filter-certainty"
        />
        <.link
          :if={@filters != %{}}
          patch={
            people_path(assigns, %{
              "q" => "",
              "group" => "",
              "age" => "",
              "want" => "",
              "certainty" => ""
            })
          }
          id="people-clear-filters"
          class="text-sm font-medium text-accent hover:underline"
        >
          Clear filters
        </.link>
      </.form>

      <div
        :if={MapSet.size(@selected_ids) > 0}
        id="people-bulk-bar"
        class="flex flex-wrap items-center gap-3 rounded-field border border-accent/30 bg-accent-soft px-4 py-3"
      >
        <span id="people-selected-count" class="text-sm font-medium text-ink">{MapSet.size(
          @selected_ids
        )} selected</span>

        <div class="flex flex-wrap gap-1">
          <button
            :for={tier <- Person.want_tiers()}
            type="button"
            id={"people-bulk-want-#{tier}"}
            phx-click="bulk_set_want_tier"
            phx-value-tier={tier}
            class={[
              "rounded-chip border border-line-strong bg-surface-raised px-2 py-1 text-xs font-medium",
              tone_class(want_tone(tier))
            ]}
          >
            {want_label(tier)}
          </button>
        </div>

        <div class="flex flex-wrap gap-1">
          <button
            :for={c <- Person.certainties()}
            type="button"
            id={"people-bulk-certainty-#{c}"}
            phx-click="bulk_set_certainty"
            phx-value-certainty={c}
            class="rounded-chip border border-line-strong bg-surface-raised px-2 py-1 text-xs font-medium text-ink-soft"
          >
            {certainty_label(c)}
          </button>
        </div>

        <.button variant="destructive" id="people-bulk-delete" phx-click="confirm_bulk_delete">
          Delete selected
        </.button>
      </div>

      <.destructive_confirm
        :if={@confirming_bulk_delete}
        id="people-bulk-delete-confirm"
        title={bulk_delete_title(@selected_persons)}
        confirm="bulk_delete_confirmed"
        cancel="cancel_bulk_delete"
      />

      <div
        id="people-header"
        class="hidden items-center gap-x-3 px-2 pb-2 text-xs font-semibold tracking-wide text-ink-soft uppercase sm:flex"
      >
        <span class="w-4" aria-hidden="true"></span>
        <div class="flex min-w-56 flex-1 gap-2">
          <.link
            patch={people_path(assigns, sort_change(assigns, :first_name))}
            id="people-sort-first-name"
            class="hover:text-ink"
          >First{sort_arrow(assigns, :first_name)}</.link>
          <.link
            patch={people_path(assigns, sort_change(assigns, :last_name))}
            id="people-sort-last-name"
            class="hover:text-ink"
          >Last{sort_arrow(assigns, :last_name)}</.link>
        </div>
        <.link
          patch={people_path(assigns, sort_change(assigns, :group))}
          id="people-sort-group"
          class="w-32 hover:text-ink"
        >Group{sort_arrow(assigns, :group)}</.link>
        <.link
          patch={people_path(assigns, sort_change(assigns, :age_category))}
          id="people-sort-age"
          class="w-24 hover:text-ink"
        >Age{sort_arrow(assigns, :age_category)}</.link>
        <.link
          patch={people_path(assigns, sort_change(assigns, :want_tier))}
          id="people-sort-want"
          class="w-28 hover:text-ink"
        >Want{sort_arrow(assigns, :want_tier)}</.link>
        <.link
          patch={people_path(assigns, sort_change(assigns, :certainty))}
          id="people-sort-certainty"
          class="w-28 hover:text-ink"
        >Certainty{sort_arrow(assigns, :certainty)}</.link>
        <span class="ml-auto w-14" aria-hidden="true"></span>
      </div>

      <div id="people-rows" phx-update="stream">
        <p id="people-empty" class="hidden py-8 text-center text-sm text-ink-faint only:block">
          No people yet. Use quick-add or paste a list above.
        </p>
        <div :for={{dom_id, row} <- @streams.rows} id={dom_id}>
          <.group_header_view :if={row.kind == :group_header} row={row} time_zone={@time_zone} />
          <.person_row_view :if={row.kind == :person} row={row} groups={@groups} />
        </div>
      </div>
    </Layouts.app>
    """
  end

  attr :row, :map, required: true
  attr :time_zone, :string, default: nil

  defp group_header_view(assigns) do
    ~H"""
    <div class="mt-4 rounded-field border border-line bg-surface px-3 py-2.5 first:mt-0">
      <div class="flex flex-wrap items-center gap-3">
        <button
          type="button"
          id={"#{@row.id}-select-all"}
          phx-click="toggle_select_group"
          phx-value-group={group_key(@row.group)}
          disabled={@row.members == []}
          class="text-xs font-medium text-accent hover:underline disabled:cursor-not-allowed disabled:opacity-40"
        >
          {if @row.selected_all?, do: "Deselect all", else: "Select all"}
        </button>

        <%= if @row.group do %>
          <input
            type="text"
            name="value"
            id={"group-#{@row.group.id}-name"}
            value={@row.group.name}
            aria-label="Group name"
            phx-blur="update_group_field"
            phx-value-id={@row.group.id}
            phx-value-field="name"
            class="rounded-field border border-transparent bg-transparent px-1 py-0.5 text-sm font-semibold text-ink transition focus:border-accent focus:ring-2 focus:ring-accent focus:outline-none"
          />
          <input
            type="text"
            name="value"
            id={"group-#{@row.group.id}-type-label"}
            value={@row.group.type_label}
            list="group-type-suggestions"
            placeholder="Type (optional)"
            aria-label="Group type"
            phx-blur="update_group_field"
            phx-value-id={@row.group.id}
            phx-value-field="type_label"
            class="w-36 rounded-field border border-line-strong bg-surface-raised px-2 py-1 text-xs text-ink-soft focus:border-accent focus:ring-2 focus:ring-accent focus:outline-none"
          />
          <span class="text-xs text-ink-faint">{length(@row.members)} {pluralize(length(@row.members))}</span>

          <button
            type="button"
            id={"group-#{@row.group.id}-history-toggle"}
            phx-click="toggle_group_history"
            phx-value-id={@row.group.id}
            class="text-xs text-ink-soft hover:text-ink"
          >
            {if @row.history_open?, do: "Hide history", else: "History"}
          </button>

          <.button
            variant="destructive"
            id={"group-#{@row.group.id}-delete"}
            phx-click="confirm_group_delete"
            phx-value-id={@row.group.id}
            class="ml-auto"
          >
            Delete group
          </.button>
        <% else %>
          <span id="group-ungrouped-name" class="text-sm font-semibold text-ink">Ungrouped</span>
          <span class="text-xs text-ink-faint">{length(@row.members)} {pluralize(length(@row.members))}</span>
        <% end %>
      </div>

      <p :if={@row.errors != []} class="mt-1 text-xs text-bad">{Enum.join(@row.errors, "; ")}</p>

      <div :if={@row.history_open? and @row.group} class="mt-3 border-t border-line pt-3">
        <.entity_history
          id={"#{@row.id}-history"}
          entity={{:group, @row.group.id}}
          entries={@row.history_entries}
          time_zone={@time_zone}
        />
      </div>

      <.destructive_confirm
        :if={@row.confirming_delete? and @row.group}
        id={"group-#{@row.group.id}-delete-confirm"}
        title={"Delete '#{@row.group.name}'?"}
        body="Members are not deleted."
        affected={Guests.group_deletion_effects(@row.group)}
        confirm="group_delete_confirmed"
        confirm_value={@row.group.id}
        cancel="cancel_group_delete"
      />
    </div>
    """
  end

  attr :row, :map, required: true
  attr :groups, :list, required: true

  defp person_row_view(assigns) do
    ~H"""
    <div class="flex flex-wrap items-center gap-x-3 gap-y-2 border-b border-line px-2 py-2.5">
      <input
        type="checkbox"
        id={"person-#{@row.person.id}-select"}
        checked={@row.selected?}
        phx-click="toggle_select"
        phx-value-id={@row.person.id}
        aria-label={"Select #{Person.display_name(@row.person)}"}
        class="size-4 rounded border-line-strong accent-accent"
      />

      <div class="flex min-w-56 flex-1 gap-2">
        <input
          type="text"
          name="value"
          id={"person-#{@row.person.id}-first-name"}
          value={@row.person.first_name}
          placeholder="First name"
          aria-label="First name"
          phx-blur="update_person_field"
          phx-value-id={@row.person.id}
          phx-value-field="first_name"
          class="w-full rounded-field border border-transparent bg-transparent px-1.5 py-1 text-sm text-ink transition focus:border-accent focus:ring-2 focus:ring-accent focus:ring-offset-1 focus:ring-offset-surface-raised focus:outline-none"
        />
        <input
          type="text"
          name="value"
          id={"person-#{@row.person.id}-last-name"}
          value={@row.person.last_name}
          placeholder="Last name"
          aria-label="Last name"
          phx-blur="update_person_field"
          phx-value-id={@row.person.id}
          phx-value-field="last_name"
          class="w-full rounded-field border border-transparent bg-transparent px-1.5 py-1 text-sm text-ink transition focus:border-accent focus:ring-2 focus:ring-accent focus:ring-offset-1 focus:ring-offset-surface-raised focus:outline-none"
        />
      </div>

      <select
        id={"person-#{@row.person.id}-group"}
        name="value"
        aria-label="Group"
        phx-change="update_person_field"
        phx-value-id={@row.person.id}
        phx-value-field="group_id"
        class="w-32 rounded-field border border-line-strong bg-surface-raised px-2 py-1 text-xs text-ink focus:border-accent focus:ring-2 focus:ring-accent focus:outline-none"
      >
        <option value="" selected={is_nil(@row.person.group_id)}>No group</option>
        <option :for={g <- @groups} value={g.id} selected={@row.person.group_id == g.id}>
          {g.name}
        </option>
      </select>

      <select
        id={"person-#{@row.person.id}-age"}
        name="value"
        aria-label="Age category"
        phx-change="update_person_field"
        phx-value-id={@row.person.id}
        phx-value-field="age_category"
        class="w-24 rounded-field border border-line-strong bg-surface-raised px-2 py-1 text-xs text-ink focus:border-accent focus:ring-2 focus:ring-accent focus:outline-none"
      >
        <option :for={a <- Person.age_categories()} value={a} selected={@row.person.age_category == a}>
          {age_label(a)}
        </option>
      </select>

      <select
        id={"person-#{@row.person.id}-want"}
        name="value"
        aria-label="Want tier"
        phx-change="update_person_field"
        phx-value-id={@row.person.id}
        phx-value-field="want_tier"
        class={[
          "w-28 rounded-field border border-line-strong bg-surface-raised px-2 py-1 text-xs font-medium focus:border-accent focus:ring-2 focus:ring-accent focus:outline-none",
          tone_class(want_tone(@row.person.want_tier))
        ]}
      >
        <option :for={w <- Person.want_tiers()} value={w} selected={@row.person.want_tier == w}>
          {want_label(w)}
        </option>
      </select>

      <select
        id={"person-#{@row.person.id}-certainty"}
        name="value"
        aria-label="Certainty"
        phx-change="update_person_field"
        phx-value-id={@row.person.id}
        phx-value-field="certainty"
        class="w-28 rounded-field border border-line-strong bg-surface-raised px-2 py-1 text-xs text-ink focus:border-accent focus:ring-2 focus:ring-accent focus:outline-none"
      >
        <option :for={c <- Person.certainties()} value={c} selected={@row.person.certainty == c}>
          {certainty_label(c)}
        </option>
      </select>

      <div class="ml-auto flex w-14 items-center justify-end gap-1 pr-1">
        <button
          type="button"
          id={"person-#{@row.person.id}-notes-toggle"}
          phx-click="toggle_notes"
          phx-value-id={@row.person.id}
          aria-label="Notes"
          class="rounded-field p-1.5 text-ink-faint transition hover:bg-surface hover:text-ink"
        >
          <.icon name="hero-pencil-square" class="size-4" />
        </button>
        <.link
          navigate={~p"/people/#{@row.person.id}"}
          id={"person-#{@row.person.id}-open"}
          aria-label="Open person"
          class="rounded-field p-1.5 text-ink-faint transition hover:bg-surface hover:text-ink"
        >
          <.icon name="hero-arrow-top-right-on-square" class="size-4" />
        </.link>
        <button
          type="button"
          id={"person-#{@row.person.id}-delete"}
          phx-click="confirm_delete"
          phx-value-id={@row.person.id}
          aria-label="Delete person"
          class="rounded-field p-1.5 text-ink-faint transition hover:bg-bad-soft hover:text-bad"
        >
          <.icon name="hero-trash" class="size-4" />
        </button>
      </div>
    </div>

    <div :if={@row.notes_open?} class="border-b border-line bg-surface px-3 py-2">
      <textarea
        name="value"
        id={"person-#{@row.person.id}-notes"}
        phx-blur="update_person_field"
        phx-value-id={@row.person.id}
        phx-value-field="notes"
        placeholder="Notes"
        aria-label="Notes"
        class="w-full rounded-field border border-line-strong bg-surface-raised px-2 py-1.5 text-sm text-ink focus:border-accent focus:ring-2 focus:ring-accent focus:outline-none"
      >{Phoenix.HTML.Form.normalize_value("textarea", @row.person.notes)}</textarea>
    </div>

    <p
      :if={@row.errors != []}
      id={"person-#{@row.person.id}-errors"}
      class="border-b border-line px-2 pb-2 text-xs text-bad"
    >
      {Enum.join(@row.errors, "; ")}
    </p>

    <.destructive_confirm
      :if={@row.confirming_delete?}
      id={"person-#{@row.person.id}-delete-confirm"}
      title={"Delete '#{Person.display_name(@row.person)}'?"}
      affected={Guests.person_deletion_effects(@row.person)}
      confirm="delete_confirmed"
      confirm_value={@row.person.id}
      cancel="cancel_delete"
    />
    """
  end
end
