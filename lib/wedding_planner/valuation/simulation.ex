defmodule WeddingPlanner.Valuation.Simulation do
  @moduledoc """
  The what-if engine (`docs/modules/invoices-and-budget.md` `BUD-20`, `BUD-21`, `BUD-22`;
  `DR-80`, `DR-81`; normative example **B4**): a preview of what a draft of hypothetical
  invitation statuses would do to every headcount and to the forecast, a person's
  **marginal cost**, and which role presets count each person (the picker's "not
  counted" filter, `INVT-04`).

  Pure (`NFR-41`): everything is read from a `WeddingPlanner.Valuation.Snapshot`, nothing
  is saved (`BUD-20`: "Nothing is saved until the user applies the change" — applying is
  `WeddingPlanner.Invitations`' job, never this module's). It takes **no options**: the
  offer engine's test-only headcount option is never passed from here, so every figure
  comes from the real headcount engine on the snapshot it is given.

  ## BUD-21, structurally

  Every figure this module reports is one of the existing engines evaluated **twice** —
  on the unmodified snapshot and on `Snapshot.apply/2`'s result — and then, for money,
  differenced with `WeddingPlanner.Money.subtract/2`:

    * forecasts, per category and overall, and every confirmed offer's committed total
      or the planning pick's total: `WeddingPlanner.Valuation.Budget.overall/3`;
    * headcounts per event and across all events (`HC-03`):
      `WeddingPlanner.Valuation.Headcount.evaluate/3`, and on the "after" side
      `Headcount.explain/3` so every count is traceable (`NFR-32`).

  Nothing here multiplies a rate by a number of people, reads an offer line, or knows
  what an included quantity, a minimum charge or a minimum spend is. So the delta cannot
  be a sum of per-person rates: the only way a person changes a figure is by changing
  the snapshot the budget engine evaluates, and every rule that engine applies —
  included quantities, minimum charges, minimum spends, invoicing complete, the planning
  pick — applies to the "after" side exactly as to the "before" side. A future change to
  those rules flows through untouched.

  ## The draft (`DR-80`, `D-11`)

  A draft is `%{person_id => %{event_id => status}}` with `status` one of `:planned`,
  `:invited`, `:accepted`, `:declined` (`INVT-01`) or `:not_invited` (no invitation row).
  It covers **invitation statuses of non-+1 persons only**:

    * a +1 has no invitations of its own and follows its host (`PER-13`), so a +1 shows up
      in a preview through its host's cells — never through a cell of its own;
    * certainty, want tier, +1 status and opt-outs are not simulated: `D-11` rules out
      scenario copies of the plan, and "what if the likely ones come" is already
      answered by the headcount presets, which is why every preview is given per preset.

  `prune/2` makes any draft valid against a snapshot (the screen calls it after every
  live update, so a person or event deleted meanwhile simply drops out);
  `changed_cells/2` and `changes/2` expect a pruned draft and raise `ArgumentError`
  otherwise — an unpruned draft is a caller bug.

  A draft becomes a `t:WeddingPlanner.Valuation.Snapshot.change/0` cell by cell, for
  every cell whose desired status differs from the person's own current one:

    * an existing invitation and `:not_invited` → `{:delete, :invitations, row.id}`;
    * an existing invitation and another status → `{:put, :invitations, %{row | status:
      to}}` — the same row, replaced in place, so the snapshot never holds two rows for
      one person × event;
    * no invitation → `{:put, :invitations, %Invitation{id: {:what_if, person_id,
      event_id}, …}}`. The id is deterministic and no loaded row can have it (loaded ids
      are integers), which is all `Snapshot.apply/2` asks of a hypothetical row.

  ## Baseline and preview (`BUD-20`)

  `baseline/2` evaluates the unmodified snapshot once — `Budget.overall/3` and
  `Headcount.evaluate/3` for every event (`EVT-04` order) and `:all_events`, under each
  of the three role presets (`PresetChoice.role_presets/1`, `DR-54`, `DR-71`) and under
  the selected single-figure preset (`HC-08`, `HC-10`; reused when it *is* one of the
  role presets) — so a live draft edit re-evaluates only the "after" side.

  `preview/2` applies the draft's changes to the baseline's snapshot, evaluates the
  "after" side the same way and pairs it with the baseline's "before", giving one
  `t:evaluation/0` per role preset and one for the selected preset:

    * `headcounts` — one row per event in `snapshot.events` order, then `:all_events`:
      `before` / `after` counts and `after_explain`, `Headcount.explain/3` on the after
      snapshot (its first step names the preset, `HC-08`);
    * `categories` — every category in `snapshot.categories` order: the category's
      Forecast formula before and after, the `delta` formula, and `offers` — each
      confirmed offer (`role: :confirmed`, its committed total) or, in the
      `:planning_pick` branch, the pick (`role: :planning_pick`, its total), before and
      after. So B4's "recomputed Venue A total" is on screen. Which offers contribute
      depends on offers only, never on guests, so both sides list the same ones;
    * `overall` — both `Budget.overall/3` results (for their Forecast and Available
      formulas, `available` and `over_budget`) and the overall `delta` formula.

  ### The delta formula (`BUD-08`, `NFR-32`)

  Label `"Change in forecast"`; steps, in order:

    1. `"Headcount preset"` → `{:preset, preset.name}` — **always**: a what-if changes
       the forecast only through a headcount, so the preset is always an input (`HC-08`);
    2. `"Forecast with the change"` → `{:money, after}`;
    3. `"Forecast now"` → `{:money, before}`;

  total `{:money, after − before}` — unrounded (`NFR-14`) and negative when the change
  lowers the forecast. The overall forecast is the sum of the category forecasts, so the
  category deltas sum to the overall delta exactly.

  ## Marginal cost (`BUD-22`, `DR-81`)

  `removal/2` is the change that removes a person: `{:delete, :persons, id}` for the
  person and, when they are a host, each of their +1s (`PER-16`), plus a delete of every
  invitation and opt-out of each removed person — `Snapshot.apply/2` has no cascades, so
  the change names every row. For a +1 it removes the +1 and its opt-outs only (a +1's
  own page asks what that +1 costs).

  `marginal_cost/2` is, per role preset, `Budget.overall/3`'s forecast on the snapshot
  minus the same on `Snapshot.apply(snapshot, removal(snapshot, id))`, as a formula
  labelled `"Marginal cost"` with steps:

    1. `"Headcount preset"` → `{:preset, preset.name}` (always);
    2. `["Forecast with ", name, " and their +1s"]` → `{:money, now}` — `" and their
       +1"` for exactly one +1 removed, no clause at all when none is;
    3. `"Forecast without"` → `{:money, without}`;

  total `{:money, now − without}`. `name` is `WeddingPlanner.Guests.Person.display_name/1`
  of the person, with the host from the snapshot put on an unnamed +1's `:host` so it
  reads "+1 of <host>". When every amount is ≥ €0 the result is never negative: every
  budget rule is monotone in the counts.

  ## Who is counted (`INVT-04`)

  `counted_roles/1` maps every person to the role presets (minimum · likely · maximum)
  whose `Headcount.counted/3` for `:all_events` includes them — `[]` means counted by
  none, which is what the picker's "not counted" filter looks for.

  Every function that needs the role presets returns `:missing` when a role is
  unassigned.
  """

  alias WeddingPlanner.Categories.Category
  alias WeddingPlanner.Events.Event
  alias WeddingPlanner.Guests.Person
  alias WeddingPlanner.Invitations.Invitation
  alias WeddingPlanner.Offers
  alias WeddingPlanner.Valuation.Budget
  alias WeddingPlanner.Valuation.Formula
  alias WeddingPlanner.Valuation.Formula.Step
  alias WeddingPlanner.Valuation.Headcount
  alias WeddingPlanner.Valuation.Preset
  alias WeddingPlanner.Valuation.PresetChoice
  alias WeddingPlanner.Valuation.Snapshot

  @roles [:minimum, :likely, :maximum]
  @statuses [:planned, :invited, :accepted, :declined, :not_invited]

  @typedoc "A desired status in a draft: an `INVT-01` status, or `:not_invited` (no row)."
  @type status :: :planned | :invited | :accepted | :declined | :not_invited

  @typedoc "Desired statuses per non-+1 person and event (see the moduledoc)."
  @type draft :: %{optional(person_id :: term()) => %{optional(event_id :: term()) => status()}}

  @typedoc "One of the three role presets (`DR-54`)."
  @type role :: :minimum | :likely | :maximum

  @typedoc "One draft cell whose desired status differs from the person's own current one."
  @type cell :: %{person: Person.t(), event: Event.t(), from: status(), to: status()}

  @typedoc """
  One headcount row of an evaluation: an event (or `:all_events`, `HC-03`), its counts
  before and after, and `Headcount.explain/3` on the after snapshot (`NFR-32`).
  """
  @type headcount_row :: %{
          event: Event.t() | :all_events,
          before: Headcount.counts(),
          after: Headcount.counts(),
          after_explain: Formula.t()
        }

  @typedoc """
  A confirmed offer's committed total (`role: :confirmed`) or the planning pick's total
  (`role: :planning_pick`), before and after.
  """
  @type offer_row :: %{
          offer: Offers.Offer.t(),
          role: :confirmed | :planning_pick,
          before: Money.t(),
          after: Money.t()
        }

  @typedoc """
  One category: its `Budget` Forecast formula before and after, the delta formula (see
  the moduledoc) and its contributing offers.
  """
  @type category_row :: %{
          category: Category.t(),
          before: Formula.t(),
          after: Formula.t(),
          delta: Formula.t(),
          offers: [offer_row()]
        }

  @typedoc """
  A whole preview under one preset: `headcounts` (every event in `EVT-04` order, then
  `:all_events`), `categories` (every category, in order) and `overall` (both
  `Budget.overall/3` results and the delta formula).
  """
  @type evaluation :: %{
          preset: Preset.t(),
          headcounts: [headcount_row()],
          categories: [category_row()],
          overall: %{before: Budget.overall(), after: Budget.overall(), delta: Formula.t()}
        }

  @typedoc "`preview/2`'s result: the changed cells, and an evaluation per role and for the selected preset."
  @type preview :: %{
          cells: [cell()],
          roles: %{minimum: evaluation(), likely: evaluation(), maximum: evaluation()},
          selected: evaluation()
        }

  @typedoc """
  One side of an evaluation, as `baseline/2` caches it: `Budget.overall/3` and one
  `Headcount.evaluate/3` per event (in `snapshot.events` order) then `:all_events`.
  """
  @type side :: %{
          overall: Budget.overall(),
          headcounts: [%{event: Event.t() | :all_events, counts: Headcount.counts()}]
        }

  @typedoc """
  The unmodified snapshot evaluated once (`baseline/2`), for any number of `preview/2`
  calls:

    * `snapshot` — the snapshot every preview applies its draft to;
    * `presets` — the three role presets;
    * `before` — the `t:side/0` of each role preset;
    * `selected` — the selected preset, the role it plays (`nil` when it is not a role
      preset) and its `t:side/0` (the role's own when `role` is set).
  """
  @type baseline :: %{
          snapshot: Snapshot.t(),
          presets: %{minimum: Preset.t(), likely: Preset.t(), maximum: Preset.t()},
          before: %{minimum: side(), likely: side(), maximum: side()},
          selected: %{preset: Preset.t(), role: role() | nil, before: side()}
        }

  @typedoc "A marginal cost under one preset: the formula (see the moduledoc) and who was removed, the person first."
  @type marginal :: %{preset: Preset.t(), formula: Formula.t(), removed: [Person.t()]}

  # -- the draft ---------------------------------------------------------------------------------

  @doc """
  `draft` restricted to what `snapshot` can take: drops persons not in
  `snapshot.persons`, +1s (`host_id` set), events not in `snapshot.events`, values that
  are not a `t:status/0`, and persons left with no events. Never raises.
  """
  @spec prune(Snapshot.t(), draft()) :: draft()
  def prune(%Snapshot{} = snapshot, draft) when is_map(draft) do
    persons = Map.new(snapshot.persons, &{&1.id, &1})
    event_ids = MapSet.new(snapshot.events, & &1.id)

    for {person_id, events} <- draft,
        match?(%Person{host_id: nil}, Map.get(persons, person_id)),
        is_map(events),
        kept <- [Map.filter(events, fn {id, to} -> id in event_ids and to in @statuses end)],
        kept != %{},
        into: %{},
        do: {person_id, kept}
  end

  @doc """
  The cells of `draft` whose desired status differs from the person's **own** current
  status for the event (`:not_invited` when there is no invitation row), as `%{person,
  event, from, to}`, in `snapshot.persons` order then `snapshot.events` order.

  Raises `ArgumentError` for a person or event not in `snapshot`, a +1, or a value that
  is not a `t:status/0` — call `prune/2` first.
  """
  @spec changed_cells(Snapshot.t(), draft()) :: [cell()]
  def changed_cells(%Snapshot{} = snapshot, draft) when is_map(draft) do
    snapshot |> changed(draft) |> Enum.map(&elem(&1, 0))
  end

  @doc """
  The `t:WeddingPlanner.Valuation.Snapshot.change/0` that turns `snapshot`'s invitations
  into `draft`'s, one entry per `changed_cells/2` cell, in the same order (see the
  moduledoc for the three cases). `[]` when nothing changes. Raises exactly like
  `changed_cells/2`.
  """
  @spec changes(Snapshot.t(), draft()) :: Snapshot.change()
  def changes(%Snapshot{} = snapshot, draft) when is_map(draft) do
    snapshot |> changed(draft) |> Enum.map(&change/1)
  end

  defp change({%{to: :not_invited}, %Invitation{id: id}}), do: {:delete, :invitations, id}

  defp change({%{to: to}, %Invitation{} = row}), do: {:put, :invitations, %{row | status: to}}

  defp change({%{person: person, event: event, to: to}, nil}) do
    {:put, :invitations,
     %Invitation{
       id: {:what_if, person.id, event.id},
       person_id: person.id,
       event_id: event.id,
       status: to
     }}
  end

  # `{cell, current_row_or_nil}` for every changed cell, in persons then events order.
  defp changed(snapshot, draft) do
    validate!(snapshot, draft)
    rows = Map.new(snapshot.invitations, &{{&1.person_id, &1.event_id}, &1})

    for person <- snapshot.persons,
        Map.has_key?(draft, person.id),
        events = Map.fetch!(draft, person.id),
        event <- snapshot.events,
        Map.has_key?(events, event.id),
        to <- [Map.fetch!(events, event.id)],
        row <- [Map.get(rows, {person.id, event.id})],
        from <- [if(row, do: row.status, else: :not_invited)],
        from != to do
      {%{person: person, event: event, from: from, to: to}, row}
    end
  end

  defp validate!(snapshot, draft) do
    persons = Map.new(snapshot.persons, &{&1.id, &1})
    event_ids = MapSet.new(snapshot.events, & &1.id)

    for {person_id, events} <- draft do
      case Map.get(persons, person_id) do
        nil ->
          raise ArgumentError, "draft names person #{inspect(person_id)}, not in the snapshot"

        %Person{host_id: nil} ->
          :ok

        %Person{} ->
          raise ArgumentError,
                "draft names +1 #{inspect(person_id)}: a +1 follows its host (PER-13, DR-80)"
      end

      unless is_map(events) do
        raise ArgumentError, "draft for person #{inspect(person_id)} is not a map of events"
      end

      for {event_id, to} <- events do
        unless event_id in event_ids do
          raise ArgumentError, "draft names event #{inspect(event_id)}, not in the snapshot"
        end

        unless to in @statuses do
          raise ArgumentError, "draft status #{inspect(to)} is not one of #{inspect(@statuses)}"
        end
      end
    end

    :ok
  end

  # -- baseline and preview ----------------------------------------------------------------------

  @doc """
  Evaluates the unmodified `snapshot` once per role preset and once for `selected`
  (reused when `selected` is one of the role presets), for any number of `preview/2`
  calls. `:missing` when `PresetChoice.role_presets/1` is `:missing`. See
  `t:baseline/0`.
  """
  @spec baseline(Snapshot.t(), selected :: Preset.t()) :: {:ok, baseline()} | :missing
  def baseline(%Snapshot{} = snapshot, %Preset{} = selected) do
    case PresetChoice.role_presets(snapshot.headcount_presets) do
      :missing ->
        :missing

      {:ok, presets} ->
        before = Map.new(presets, fn {role, preset} -> {role, side(snapshot, preset)} end)
        role = Enum.find(@roles, &(Map.fetch!(presets, &1) == selected))
        selected_before = if role, do: Map.fetch!(before, role), else: side(snapshot, selected)

        {:ok,
         %{
           snapshot: snapshot,
           presets: presets,
           before: before,
           selected: %{preset: selected, role: role, before: selected_before}
         }}
    end
  end

  @doc """
  The effect of `draft` (pruned — see `prune/2`; raises like `changed_cells/2`
  otherwise): `changes/2` against the baseline's snapshot, applied with
  `Snapshot.apply/2`, evaluated under every role preset and the selected preset, and
  paired with the baseline's "before". An empty draft gives `cells: []` and every delta
  €0. See the moduledoc and `t:evaluation/0`.
  """
  @spec preview(baseline(), draft()) :: preview()
  def preview(%{snapshot: %Snapshot{} = snapshot} = baseline, draft) when is_map(draft) do
    changed = changed(snapshot, draft)
    cells = Enum.map(changed, &elem(&1, 0))
    after_snapshot = Snapshot.apply(snapshot, Enum.map(changed, &change/1))

    roles =
      Map.new(@roles, fn role ->
        preset = Map.fetch!(baseline.presets, role)
        {role, evaluation(Map.fetch!(baseline.before, role), after_snapshot, preset)}
      end)

    selected =
      case baseline.selected do
        %{role: nil, preset: preset, before: before} -> evaluation(before, after_snapshot, preset)
        %{role: role} -> Map.fetch!(roles, role)
      end

    %{cells: cells, roles: roles, selected: selected}
  end

  defp side(snapshot, preset) do
    %{
      overall: Budget.overall(snapshot, preset),
      headcounts:
        for target <- snapshot.events ++ [:all_events] do
          %{event: target, counts: Headcount.evaluate(snapshot, preset, target)}
        end
    }
  end

  defp evaluation(before, after_snapshot, preset) do
    after_overall = Budget.overall(after_snapshot, preset)

    %{
      preset: preset,
      headcounts:
        for %{event: target, counts: counts} <- before.headcounts do
          %{
            event: target,
            before: counts,
            after: Headcount.evaluate(after_snapshot, preset, target),
            after_explain: Headcount.explain(after_snapshot, preset, target)
          }
        end,
      categories:
        Enum.zip_with(before.overall.categories, after_overall.categories, fn b, a ->
          %{
            category: a.category,
            before: b.forecast,
            after: a.forecast,
            delta: delta(preset, money(a.forecast), money(b.forecast)),
            offers: offer_rows(b, a)
          }
        end),
      overall: %{
        before: before.overall,
        after: after_overall,
        delta: delta(preset, money(after_overall.forecast), money(before.overall.forecast))
      }
    }
  end

  # Which offers contribute depends on the offers alone, so both sides list the same ones;
  # the guard makes a mismatch loud instead of pairing unrelated offers.
  defp offer_rows(%{branch: :confirmed} = b, %{branch: :confirmed} = a) do
    Enum.zip_with(b.confirmed_offers, a.confirmed_offers, fn before, after_ ->
      offer_row(before.offer, after_.offer, :confirmed, before.committed, after_.committed)
    end)
  end

  defp offer_rows(%{branch: :planning_pick} = b, %{branch: :planning_pick} = a) do
    [
      offer_row(
        b.planning_pick.offer,
        a.planning_pick.offer,
        :planning_pick,
        b.planning_pick.total,
        a.planning_pick.total
      )
    ]
  end

  defp offer_rows(%{branch: branch}, %{branch: branch}), do: []

  defp offer_row(%Offers.Offer{id: id}, %Offers.Offer{id: id} = offer, role, before, after_) do
    %{offer: offer, role: role, before: money(before), after: money(after_)}
  end

  defp delta(%Preset{name: name}, after_, before) do
    %Formula{
      label: "Change in forecast",
      steps: [
        preset_step(name),
        %Step{label: "Forecast with the change", value: {:money, after_}},
        %Step{label: "Forecast now", value: {:money, before}}
      ],
      total: {:money, WeddingPlanner.Money.subtract(after_, before)}
    }
  end

  # -- marginal cost -----------------------------------------------------------------------------

  @doc """
  The change that removes the person with `person_id` (`DR-81`): the person, their +1s
  when they are a host (`PER-16`), and every invitation and opt-out of each removed
  person; for a +1, the +1 and its opt-outs. `Snapshot.apply/2` has no cascades, so the
  change names every row. Raises `ArgumentError` for an id not in `snapshot.persons`.
  """
  @spec removal(Snapshot.t(), person_id :: term()) :: Snapshot.change()
  def removal(%Snapshot{} = snapshot, person_id) do
    removed = removed_persons(snapshot, person_id)
    ids = MapSet.new(removed, & &1.id)

    Enum.map(removed, &{:delete, :persons, &1.id}) ++
      for(row <- snapshot.invitations, row.person_id in ids, do: {:delete, :invitations, row.id}) ++
      for(
        row <- snapshot.plus_one_opt_outs,
        row.person_id in ids,
        do: {:delete, :plus_one_opt_outs, row.id}
      )
  end

  @doc """
  The person's marginal cost (`BUD-22`, `DR-81`) under each role preset: the forecast
  with the snapshot as it is minus the forecast after `removal/2`, as a formula (see the
  moduledoc), with the removed persons (the person first). `:missing` when a role preset
  is unassigned; raises `ArgumentError` for an id not in `snapshot.persons`.
  """
  @spec marginal_cost(Snapshot.t(), person_id :: term()) ::
          {:ok, %{minimum: marginal(), likely: marginal(), maximum: marginal()}} | :missing
  def marginal_cost(%Snapshot{} = snapshot, person_id) do
    removed = removed_persons(snapshot, person_id)

    case PresetChoice.role_presets(snapshot.headcount_presets) do
      :missing ->
        :missing

      {:ok, presets} ->
        without = Snapshot.apply(snapshot, removal(snapshot, person_id))
        with_label = with_label(snapshot, removed)

        {:ok,
         Map.new(presets, fn {role, preset} ->
           now = money(Budget.overall(snapshot, preset).forecast)
           after_ = money(Budget.overall(without, preset).forecast)

           formula = %Formula{
             label: "Marginal cost",
             steps: [
               preset_step(preset.name),
               %Step{label: with_label, value: {:money, now}},
               %Step{label: "Forecast without", value: {:money, after_}}
             ],
             total: {:money, WeddingPlanner.Money.subtract(now, after_)}
           }

           {role, %{preset: preset, formula: formula, removed: removed}}
         end)}
    end
  end

  defp removed_persons(snapshot, person_id) do
    case Enum.find(snapshot.persons, &(&1.id == person_id)) do
      nil ->
        raise ArgumentError, "no person #{inspect(person_id)} in the snapshot"

      %Person{host_id: nil} = host ->
        [host | Enum.filter(snapshot.persons, &(&1.host_id == person_id))]

      %Person{} = plus_one ->
        [plus_one]
    end
  end

  defp with_label(snapshot, [person | plus_ones]) do
    clause =
      case plus_ones do
        [] -> []
        [_one] -> [" and their +1"]
        _many -> [" and their +1s"]
      end

    ["Forecast with ", name(snapshot, person) | clause]
  end

  # `Person.display_name/1` reads an unnamed +1's host from `:host`; put the snapshot's there.
  defp name(_snapshot, %Person{host_id: nil} = person), do: Person.display_name(person)

  defp name(snapshot, %Person{host_id: host_id} = plus_one) do
    host = Enum.find(snapshot.persons, &(&1.id == host_id))
    Person.display_name(%{plus_one | host: host})
  end

  # -- who is counted ----------------------------------------------------------------------------

  @doc """
  Every person id in `snapshot.persons` mapped to the role presets, in minimum · likely ·
  maximum order, whose `Headcount.counted/3` for `:all_events` includes them (`[]`:
  counted by none — `INVT-04`'s "not counted"). `:missing` when a role preset is
  unassigned.
  """
  @spec counted_roles(Snapshot.t()) :: {:ok, %{optional(term()) => [role()]}} | :missing
  def counted_roles(%Snapshot{} = snapshot) do
    case PresetChoice.role_presets(snapshot.headcount_presets) do
      :missing ->
        :missing

      {:ok, presets} ->
        counted =
          Map.new(presets, fn {role, preset} ->
            ids = snapshot |> Headcount.counted(preset, :all_events) |> MapSet.new(& &1.person.id)
            {role, ids}
          end)

        {:ok,
         Map.new(snapshot.persons, fn %Person{id: id} ->
           {id, for(role <- @roles, MapSet.member?(Map.fetch!(counted, role), id), do: role)}
         end)}
    end
  end

  # -- helpers -----------------------------------------------------------------------------------

  # HC-08: the preset used is always named, with the label every engine uses.
  defp preset_step(name), do: %Step{label: "Headcount preset", value: {:preset, name}}

  defp money(%Formula{total: {:money, %Money{} = money}}), do: money
end
