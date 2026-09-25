defmodule WeddingPlannerWeb.WhatIfView do
  @moduledoc """
  Builds the plain map `WeddingPlannerWeb.Components.WhatIfComponents` renders on
  `/what-if` (task 89; `docs/modules/invoices-and-budget.md` `BUD-20`, `BUD-21`,
  `INVT-04`; `DR-80`, `DR-82`) — the `WeddingPlannerWeb.BudgetOverview` precedent: a
  pure map of display strings plus `WeddingPlannerWeb.FormulaPresenter` output, built
  once per render from a fresh `WeddingPlanner.Valuation.Simulation.preview/2` result (or
  `:missing`, no role preset assigned), the snapshot it was built from, the current
  selection, the transient draft and the transient selected preset id. No database
  access, no LiveView concerns.

  Every count, amount and formula comes straight from `WeddingPlanner.Valuation.Simulation`
  — nothing here re-derives a business rule (`NFR-41`). The two places this module does
  its own subtraction are both safe, non-business-rule differences the engine does not
  already hand back as a formula:

    * a headcount delta (`"78 → 81 (+3)"`) — the engine gives `before`/`after` **totals**,
      already-correct integers (`HC-01`…`HC-08`), so subtracting the two here cannot
      reintroduce the "naive per-person sum" trap `BUD-21`/`FP-89f` guards against (that
      trap is specifically about *money* — skipping minimum charges, included
      quantities, and the like by summing rates instead of recomputing the forecast).
    * every **money** delta (category, overall) is instead rendered straight from the
      engine's own precomputed `Formula`'s `:total` (`category_row.delta`,
      `overall.delta`) through `Format.signed_money/1` — never subtracted here (`FP-89f`).

  ## Three role-preset values, one selected-preset detail (`DR-71`, `HC-10`)

  Every three-value figure (a headcount row's count, a category's signed delta and its
  before → after pair, the overall forecast change, Available after) is built into
  exactly the shape `WeddingPlannerWeb.Components.BudgetComponents.role_values/1` already
  expects (`WeddingPlannerWeb.BudgetOverview.figure/0`'s shape, reused verbatim — no new
  attrs needed there), so tapping any of them both selects that role's preset and opens
  the row's own formula in one interaction (`NFR-32`, `BUD-08`). Only the **selected**
  preset drives every offer's before → after line and every formula's own steps — never
  the three-value lists (`FP-89b`).

  ## The draft never leaves this module as anything but display strings

  A cell's *hypothetical* status (what the draft says) and its *real* one (what
  `snapshot.invitations` says right now) are read here, once, from the same snapshot the
  preview was built from — never from a second query — so "now: invited" only shows when
  the two genuinely disagree.

  ## The picker's search/filter state is not this module's concern

  `picker_candidates/0` is the full B-list candidate pool (every non-+1, unselected
  person with their counted-roles caption); narrowing it by the free-text search and the
  two filter chips is plain string/boolean matching over already-loaded data, not a
  business rule, so `WeddingPlannerWeb.Live.WhatIfLive` does it directly over this list
  rather than this module growing a sixth argument for transient UI-only state.
  """

  alias WeddingPlanner.Events.Event
  alias WeddingPlanner.Guests.Person
  alias WeddingPlanner.Invitations.Invitation
  alias WeddingPlanner.Valuation.Formula
  alias WeddingPlanner.Valuation.PresetChoice
  alias WeddingPlanner.Valuation.Simulation
  alias WeddingPlanner.Valuation.Snapshot
  alias WeddingPlannerWeb.Format
  alias WeddingPlannerWeb.FormulaPresenter

  @roles [:minimum, :likely, :maximum]

  @typedoc "See `WeddingPlannerWeb.BudgetOverview.figure/0` — the identical shape, reused by `role_values/1`."
  @type figure :: %{
          role: :minimum | :likely | :maximum,
          value: String.t(),
          preset_id: term(),
          preset_name: String.t()
        }

  @typedoc "See `WeddingPlannerWeb.BudgetOverview.ranged/0` — the identical shape, reused by `role_values/1`."
  @type ranged ::
          :missing
          | %{equal?: boolean(), minimum: figure(), likely: figure(), maximum: figure()}

  @doc """
  Builds the `/what-if` view model.

    * `preview` — a `WeddingPlanner.Valuation.Simulation.preview()`, or `:missing` when no
      role preset is assigned (`baseline/2`'s own `:missing`).
    * `snapshot` — the snapshot `preview` was built from (or, when `preview` is
      `:missing`, the snapshot loaded anyway, so the picker still works).
    * `selection` — the currently picked non-+1 `WeddingPlanner.Guests.Person` structs,
      in selection order.
    * `draft` — the transient, already-pruned draft (`Simulation.prune/2`).
    * `selected_preset_id` — the transient single-figure preset id (`HC-10`).
  """
  @spec build(
          Simulation.preview() | :missing,
          Snapshot.t(),
          [Person.t()],
          Simulation.draft(),
          term()
        ) :: map()
  def build(preview, %Snapshot{} = snapshot, selection, draft, selected_preset_id)
      when is_list(selection) and is_map(draft) do
    cells = Simulation.changed_cells(snapshot, draft)
    invitation_index = Map.new(snapshot.invitations, &{{&1.person_id, &1.event_id}, &1.status})
    selected_ids = MapSet.new(selection, & &1.id)

    %{
      presets_missing?: preview == :missing,
      preset_selector: preset_selector(snapshot, selected_preset_id),
      likely_preset_name: likely_preset_name(snapshot),
      picker_candidates: picker_candidates(snapshot, selected_ids),
      groups: Enum.map(snapshot.groups, &%{id: &1.id, name: &1.name}),
      status_options: status_options(),
      events: Enum.map(snapshot.events, &%{id: &1.id, name: &1.name}),
      person_cards: person_cards(snapshot, selection, draft, invitation_index),
      has_selection?: selection != [],
      has_changes?: cells != [],
      summary: summary(cells),
      apply: apply_view(cells)
    }
    |> Map.merge(preview_sections(preview))
  end

  @doc "The label for one `Invitations.Invitation` status, or `:not_invited` (no row)."
  @spec status_label(Invitation.status() | :not_invited) :: String.t()
  def status_label(:not_invited), do: "Not invited"
  def status_label(:planned), do: "Planned"
  def status_label(:invited), do: "Invited"
  def status_label(:accepted), do: "Accepted"
  def status_label(:declined), do: "Declined"

  @doc """
  The flash text for a successfully applied what-if (`DR-83`), from the **actual** number
  of rows `WeddingPlanner.Invitations.apply_what_if/2` reports changed — never from the
  draft's pre-apply count, which a race (`{:error, :stale}` aside) could make stale.
  """
  @spec applied_flash(non_neg_integer()) :: String.t()
  def applied_flash(count) do
    "Applied #{count} #{pluralize(count, "invitation change", "invitation changes")}"
  end

  # -- header: preset selector ------------------------------------------------------------------

  defp preset_selector(snapshot, selected_preset_id) do
    presets = snapshot.headcount_presets
    selected = PresetChoice.find(presets, selected_preset_id)

    %{
      presets: Enum.map(presets, &%{id: &1.id, name: &1.name}),
      selected: selected && selected.id
    }
  end

  defp likely_preset_name(snapshot) do
    case PresetChoice.role_presets(snapshot.headcount_presets) do
      {:ok, %{likely: likely}} -> likely.name
      :missing -> "Likely"
    end
  end

  # -- picker (INVT-04's B-list) ------------------------------------------------------------------

  defp picker_candidates(snapshot, selected_ids) do
    counted = counted_roles(snapshot)

    snapshot.persons
    |> Enum.reject(&(Person.plus_one?(&1) or MapSet.member?(selected_ids, &1.id)))
    |> Enum.sort_by(&String.downcase(Person.display_name(&1)))
    |> Enum.map(fn person ->
      roles = Map.get(counted, person.id, [])

      %{
        id: person.id,
        name: Person.display_name(person),
        counted_caption: counted_caption(roles),
        not_counted_under_likely?: :likely not in roles,
        want_maybe?: person.want_tier == :maybe
      }
    end)
  end

  defp counted_roles(snapshot) do
    case Simulation.counted_roles(snapshot) do
      {:ok, roles} -> roles
      :missing -> %{}
    end
  end

  defp counted_caption([]), do: "Not counted under any preset"
  defp counted_caption([:minimum, :likely, :maximum]), do: "Counted under every preset"
  defp counted_caption(roles), do: "Counted under " <> Enum.map_join(roles, ", ", &role_label/1)

  defp role_label(:minimum), do: "Minimum"
  defp role_label(:likely), do: "Likely"
  defp role_label(:maximum), do: "Maximum"

  @doc "The five draft-cell statuses, `:not_invited` first (person_live.ex's own idiom)."
  @spec status_options() :: [%{value: String.t(), label: String.t()}]
  def status_options do
    Enum.map(
      [:not_invited | Invitation.statuses()],
      &%{value: to_string(&1), label: status_label(&1)}
    )
  end

  # -- draft editor (DR-80: +1s follow their host, PER-13) -----------------------------------------

  defp person_cards(snapshot, selection, draft, invitation_index) do
    Enum.map(selection, fn person ->
      %{
        id: person.id,
        name: Person.display_name(person),
        plus_ones: plus_ones_of(snapshot, person),
        cells: cells_of(snapshot, person, draft, invitation_index)
      }
    end)
  end

  # `Person.display_name/1` needs `:host` preloaded for an unnamed +1 (it reads the
  # host's name for "+1 of <host>") — a bare `snapshot.persons` row never carries it, so
  # it is set explicitly from the host struct already in hand (`PersonLive`'s own
  # `load_plus_ones/1` idiom).
  defp plus_ones_of(snapshot, %Person{id: host_id} = host) do
    for %Person{host_id: ^host_id} = plus_one <- snapshot.persons,
        do: %{id: plus_one.id, name: Person.display_name(%{plus_one | host: host})}
  end

  defp cells_of(snapshot, %Person{id: person_id}, draft, invitation_index) do
    draft_events = Map.get(draft, person_id, %{})

    for %Event{} = event <- snapshot.events do
      real = Map.get(invitation_index, {person_id, event.id}, :not_invited)
      hypothetical = Map.get(draft_events, event.id, real)

      %{
        event_id: event.id,
        event_name: event.name,
        form_id: "what-if-cell-#{person_id}-#{event.id}-form",
        select_id: "what-if-cell-#{person_id}-#{event.id}",
        value: to_string(hypothetical),
        changed?: hypothetical != real,
        real_label: if(hypothetical != real, do: "now: #{status_label(real)}")
      }
    end
  end

  # -- summary and apply (BUD-20, DR-83) ------------------------------------------------------------

  defp summary([]), do: "No changes yet"

  defp summary(cells) do
    people = distinct_people(cells)

    base =
      "#{length(cells)} #{pluralize(length(cells), "change", "changes")} for #{people_phrase(people)}"

    overwrite_suffix(base, cells)
  end

  defp apply_view(cells) do
    people = distinct_people(cells)

    %{
      summary:
        "#{length(cells)} #{pluralize(length(cells), "invitation change", "invitation changes")}" <>
          " for #{people_phrase(people)}",
      overwrites?: Enum.any?(cells, &(&1.from in [:accepted, :declined])),
      changes:
        cells
        |> Enum.with_index()
        |> Enum.map(fn {%{person: person, event: event, from: from, to: to}, index} ->
          %{
            id: "what-if-apply-confirm-change-#{index}",
            text:
              "#{Person.display_name(person)} — #{event.name}: #{status_label(from)} → #{status_label(to)}"
          }
        end)
    }
  end

  defp distinct_people(cells), do: cells |> Enum.map(& &1.person.id) |> Enum.uniq() |> length()

  defp people_phrase(people), do: "#{people} #{pluralize(people, "person", "people")}"

  defp overwrite_suffix(base, cells) do
    overwrites = Enum.count(cells, &(&1.from in [:accepted, :declined]))

    if overwrites > 0 do
      base <> " — overwrites #{overwrites} #{pluralize(overwrites, "RSVP", "RSVPs")}"
    else
      base
    end
  end

  defp pluralize(1, singular, _plural), do: singular
  defp pluralize(_n, _singular, plural), do: plural

  # -- preview sections (:missing when no role preset is assigned) ---------------------------------

  defp preview_sections(:missing) do
    %{
      headcount_rows: [],
      events_unchanged_count: 0,
      category_rows: [],
      categories_unchanged_count: 0,
      overall: :missing
    }
  end

  defp preview_sections(%{roles: roles, selected: selected}) do
    {category_rows, unchanged_count} = category_rows(roles, selected)
    {headcount_rows, events_unchanged_count} = headcount_rows(roles, selected)

    %{
      headcount_rows: headcount_rows,
      events_unchanged_count: events_unchanged_count,
      category_rows: category_rows,
      categories_unchanged_count: unchanged_count,
      overall: overall_section(roles, selected)
    }
  end

  # -- headcount rows (HC-03, NFR-32) -----------------------------------------------------------

  # Mirrors `category_rows/2`'s "unchanged, counted not listed" pattern: an event's
  # headcount whose total does not move under any role is noise on a screen whose whole
  # point is "what does this cost" — but `:all_events` is the one row that always
  # matters (it is what `#what-if-summary`'s claim is ultimately checked against), so it
  # is never filtered out even when, coincidentally, its own total does not move.
  defp headcount_rows(roles, selected) do
    count = length(selected.headcounts)

    {rows, unchanged} =
      Enum.reduce(0..(count - 1)//1, {[], 0}, fn index, {rows, unchanged} ->
        selected_row = Enum.at(selected.headcounts, index)
        by_role = Map.new(@roles, &{&1, Enum.at(Map.fetch!(roles, &1).headcounts, index)})

        if selected_row.event == :all_events or headcount_changed?(by_role) do
          {[headcount_row(roles, selected_row, by_role) | rows], unchanged}
        else
          {rows, unchanged + 1}
        end
      end)

    {Enum.reverse(rows), unchanged}
  end

  defp headcount_changed?(by_role) do
    Enum.any?(@roles, fn role ->
      row = Map.fetch!(by_role, role)
      row.after.total != row.before.total
    end)
  end

  defp headcount_row(roles, selected_row, by_role) do
    key = headcount_key(selected_row.event)

    %{
      id: "what-if-headcount-#{key}",
      name: headcount_label(selected_row.event),
      values: count_ranged(roles, by_role),
      formula_id: "what-if-headcount-#{key}-formula",
      formula: FormulaPresenter.present(selected_row.after_explain),
      before_display: counts_display(selected_row.before),
      after_display: counts_display(selected_row.after)
    }
  end

  defp headcount_key(:all_events), do: "all"
  defp headcount_key(%Event{id: id}), do: to_string(id)

  defp headcount_label(:all_events), do: "All events"
  defp headcount_label(%Event{name: name}), do: name

  defp counts_display(%{adults: adults, children: children}) do
    "#{adults} #{noun(adults, "adult", "adults")} + #{children} #{noun(children, "child", "children")}"
  end

  defp noun(1, singular, _plural), do: singular
  defp noun(_n, _singular, plural), do: plural

  defp count_ranged(roles, by_role) do
    entries =
      Map.new(@roles, fn role ->
        preset = Map.fetch!(roles, role).preset
        row = Map.fetch!(by_role, role)
        delta = row.after.total - row.before.total
        value = "#{row.before.total} → #{row.after.total} (#{signed_count(delta)})"
        {role, {preset, {row.before.total, row.after.total}, value}}
      end)

    build_ranged(entries)
  end

  defp signed_count(0), do: "+0"
  defp signed_count(n) when n > 0, do: "+#{n}"
  defp signed_count(n), do: "−#{abs(n)}"

  # -- category rows (BUD-21, B4, NFR-32) --------------------------------------------------------

  defp category_rows(roles, selected) do
    count = length(selected.categories)

    rows =
      for index <- 0..(count - 1)//1,
          by_role = Map.new(@roles, &{&1, Enum.at(Map.fetch!(roles, &1).categories, index)}),
          category_changed?(by_role) do
        category_row(roles, Enum.at(selected.categories, index), by_role)
      end

    {rows, count - length(rows)}
  end

  defp category_changed?(by_role) do
    Enum.any?(@roles, fn role ->
      WeddingPlanner.Money.compare(formula_money(Map.fetch!(by_role, role).delta), zero()) != :eq
    end)
  end

  defp category_row(roles, selected_cat, by_role) do
    id = "what-if-category-#{selected_cat.category.id}"

    delta_entries =
      Map.new(@roles, fn role ->
        preset = Map.fetch!(roles, role).preset
        money = formula_money(Map.fetch!(by_role, role).delta)
        {role, {preset, money, Format.signed_money(money)}}
      end)

    before_after_entries =
      Map.new(@roles, fn role ->
        preset = Map.fetch!(roles, role).preset
        cat = Map.fetch!(by_role, role)
        before_money = formula_money(cat.before)
        after_money = formula_money(cat.after)
        value = "#{Format.money(before_money)} → #{Format.money(after_money)}"
        {role, {preset, {before_money, after_money}, value}}
      end)

    %{
      id: id,
      name: selected_cat.category.name,
      deltas: build_ranged(delta_entries),
      delta_formula_id: "#{id}-delta-formula",
      delta_formula: FormulaPresenter.present(selected_cat.delta),
      before_after: build_ranged(before_after_entries),
      offers: Enum.map(selected_cat.offers, &offer_row(id, &1)),
      after_formula_id: "#{id}-after-formula",
      after_formula: FormulaPresenter.present(selected_cat.after)
    }
  end

  defp offer_row(category_id, %{offer: offer, before: before, after: after_}) do
    %{
      id: "#{category_id}-offer-#{offer.id}",
      label: "#{offer.vendor_name} #{Format.money(before)} → #{Format.money(after_)}"
    }
  end

  # -- overall (BUD-08, NFR-32) -------------------------------------------------------------------

  defp overall_section(roles, selected) do
    delta_formula_id = "what-if-overall-delta-formula"
    available_formula_id = "what-if-overall-available-formula"

    forecast_change_entries =
      Map.new(@roles, fn role ->
        evaluation = Map.fetch!(roles, role)
        money = formula_money(evaluation.overall.delta)
        {role, {evaluation.preset, money, Format.signed_money(money)}}
      end)

    no_budget? = Enum.any?(@roles, &(Map.fetch!(roles, &1).overall.after.available == :no_budget))

    available_entries =
      unless no_budget? do
        Map.new(@roles, fn role ->
          evaluation = Map.fetch!(roles, role)
          money = formula_money(evaluation.overall.after.available)
          {role, {evaluation.preset, money, Format.money(money)}}
        end)
      end

    over_budget = selected.overall.after.over_budget

    %{
      forecast_change: build_ranged(forecast_change_entries),
      delta_formula_id: delta_formula_id,
      delta_formula: FormulaPresenter.present(selected.overall.delta),
      no_budget?: no_budget?,
      available_after: if(no_budget?, do: :missing, else: build_ranged(available_entries)),
      available_formula_id: available_formula_id,
      available_formula:
        unless(no_budget?, do: FormulaPresenter.present(selected.overall.after.available)),
      over_budget_after?: not is_nil(over_budget),
      over_budget_text: over_budget && Format.money(over_budget)
    }
  end

  # -- the shared ranged()/figure() builder (`WeddingPlannerWeb.BudgetOverview.ranged/0`) ---------

  # `entries` is `%{role => {%Preset{}, raw, display_string}}` — `raw` is whatever `==`
  # (or, for `%Money{}`, `WeddingPlanner.Money.compare/2`) decides `:equal?` from: an
  # integer, a `{before, after}` tuple of integers, or a `%Money{}`.
  defp build_ranged(entries) do
    figures =
      Map.new(entries, fn {role, {preset, _raw, value}} ->
        {role, %{role: role, value: value, preset_id: preset.id, preset_name: preset.name}}
      end)

    raws = Map.new(entries, fn {role, {_p, raw, _v}} -> {role, raw} end)
    equal? = raw_eq?(raws.minimum, raws.likely) and raw_eq?(raws.likely, raws.maximum)

    Map.put(figures, :equal?, equal?)
  end

  defp raw_eq?(%Money{} = a, %Money{} = b), do: WeddingPlanner.Money.compare(a, b) == :eq
  defp raw_eq?(a, b), do: a == b

  defp formula_money(%Formula{total: {:money, %Money{} = money}}), do: money

  defp zero, do: WeddingPlanner.Money.new(0)
end
