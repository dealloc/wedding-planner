defmodule WeddingPlannerWeb.WhatIfViewTest do
  @moduledoc """
  `WeddingPlannerWeb.WhatIfView.build/5` (task 89; `BUD-20`, `BUD-21`, normative example
  **B4**, `HC-10`, `DR-71`): pure, over `WeddingPlanner.Valuation.Simulation` results
  built from in-memory snapshots (`WeddingPlanner.BudgetSnapshots.b1/0` plus the B4
  household). The household fixture (`with_household/2`, `household_draft/1`) is
  copied from `WeddingPlanner.Valuation.SimulationTest` — the existing convention: each
  test file keeps its own private fixture helpers rather than sharing them.

  Named fail-proofs (see `.claude/tasks/89-what-if-screen.md`):

    * **FP-89b** — make the three role values follow the selected preset instead of
      their own role → "the selected preset (HC-10)" describe block fails.
    * **FP-89f** — render a delta with `Format.money/1` of a subtraction done in the
      view (the naive per-person sum, `€ 246,00` here) instead of the engine's own
      `Formula` → the B4 describe block fails (asserts `€ 76,00`, refutes `246,00`
      appearing anywhere).
  """
  use ExUnit.Case, async: true

  alias WeddingPlanner.BudgetSnapshots
  alias WeddingPlanner.Guests.Person
  alias WeddingPlanner.NormativeExamples, as: NE
  alias WeddingPlanner.Valuation.Preset
  alias WeddingPlanner.Valuation.Simulation
  alias WeddingPlannerWeb.WhatIfView

  @dinner_id 1

  # -- fixture helpers (copied from `WeddingPlanner.Valuation.SimulationTest`) --------------

  defp role_preset(role), do: Enum.find(Preset.defaults(), &(&1.role == role))
  defp likely, do: role_preset(:likely)
  defp minimum, do: role_preset(:minimum)

  defp b1, do: BudgetSnapshots.b1().snapshot

  # B4's household (`NE.given("B4")`: 2 adults + 1 child): persons 3001, 3002 (adults),
  # 3003 (child), want tier *maybe* (the B-list, `INVT-04`), no invitations.
  defp with_household(snapshot, certainty) do
    %{what_if: %{adds: %{adults: 2, children: 1}}} = NE.given("B4")

    household =
      for {id, age} <- [{3001, :adult}, {3002, :adult}, {3003, :child}] do
        %Person{
          id: id,
          first_name: "Hypo",
          last_name: Integer.to_string(id),
          age_category: age,
          certainty: certainty,
          want_tier: :maybe
        }
      end

    %{snapshot | persons: snapshot.persons ++ household}
  end

  defp household_draft(status \\ :invited),
    do: Map.new([3001, 3002, 3003], &{&1, %{@dinner_id => status}})

  defp household(snapshot), do: Enum.filter(snapshot.persons, &(&1.id in [3001, 3002, 3003]))

  defp build_vm(snapshot, draft, selected \\ likely()) do
    {:ok, baseline} = Simulation.baseline(snapshot, selected)
    preview = Simulation.preview(baseline, draft)
    WhatIfView.build(preview, snapshot, household(snapshot), draft, selected.id)
  end

  defp category(vm, name), do: Enum.find(vm.category_rows, &(&1.name == name))
  defp headcount(vm, name), do: Enum.find(vm.headcount_rows, &(&1.name == name))

  # -- 1. role order and collapsing ---------------------------------------------------------

  describe "role order and collapsing" do
    test "headcount and category rows carry three role values named in role order; equal values collapse; unchanged categories are counted, not listed" do
      snapshot = with_household(BudgetSnapshots.branches().snapshot, :likely)
      vm = build_vm(snapshot, household_draft())

      dinner = headcount(vm, "Dinner")
      assert dinner.values.minimum.role == :minimum
      assert dinner.values.likely.role == :likely
      assert dinner.values.maximum.role == :maximum
      # A *likely* household is not counted by Minimum, so Minimum's headcount does not
      # move the same way Likely/Maximum's do — the three roles genuinely disagree here.
      refute dinner.values.equal?

      venue = category(vm, "Venue")
      assert venue.deltas.minimum.role == :minimum
      assert venue.deltas.likely.role == :likely
      assert venue.deltas.maximum.role == :maximum

      # Church has no target and no offers (`:no_target`, €0) — its delta is €0 under
      # every role regardless of who is invited — counted in "unchanged", never listed.
      refute category(vm, "Church")
      assert vm.categories_unchanged_count > 0
      assert length(vm.category_rows) + vm.categories_unchanged_count == 5
    end
  end

  # -- 1b. unchanged events (orchestrator amendment, layout compaction) ----------------------

  describe "unchanged events" do
    test "an event nobody's status touches is counted in \"N events unchanged\", not listed; All events always shows" do
      snapshot = with_household(BudgetSnapshots.branches().snapshot, :likely)
      reception = %WeddingPlanner.Events.Event{id: 2, name: "Reception", sort_order: 2}
      snapshot = %{snapshot | events: snapshot.events ++ [reception]}

      vm = build_vm(snapshot, household_draft())

      # Dinner changes (the household's draft invites them to it); Reception is
      # untouched by anything in the draft, so its own headcount does not move under
      # any role — counted in "N events unchanged", never listed (mirrors
      # `categories_unchanged_count`'s own pattern above). `:all_events` always shows,
      # even though its own count here happens to move too (it sums Dinner).
      assert headcount(vm, "Dinner")
      refute headcount(vm, "Reception")
      assert headcount(vm, "All events")
      assert vm.events_unchanged_count == 1
      assert length(vm.headcount_rows) + vm.events_unchanged_count == length(snapshot.events) + 1
    end
  end

  # -- 2. B4 --------------------------------------------------------------------------------

  describe "normative example B4 (real engines, no seam)" do
    @tag example: "B4"
    test "Venue's row shows Venue A € 11.726,00 → € 11.802,00 under Likely and '+€ 76,00'; the naive '+€ 246,00' appears nowhere" do
      %{what_if: %{event: "Dinner", status: status}} = NE.given("B4")
      snapshot = with_household(b1(), :likely)
      vm = build_vm(snapshot, household_draft(status))

      venue = category(vm, "Venue")
      assert venue.deltas.likely.value == "+€ 76,00"

      assert [offer] = venue.offers
      assert offer.label == "Venue A € 11.726,00 → € 11.802,00"

      refute inspect(vm) =~ "246,00"
    end
  end

  # -- 3. the selected preset (HC-10) --------------------------------------------------------

  describe "the selected preset (HC-10)" do
    test "drives the formulas and the offer before → after lines only, never the three-value lists" do
      snapshot = with_household(b1(), :likely)
      draft = household_draft()

      vm_likely = build_vm(snapshot, draft, likely())
      vm_minimum = build_vm(snapshot, draft, minimum())

      venue_likely = category(vm_likely, "Venue")
      venue_minimum = category(vm_minimum, "Venue")

      # The three-value lists never change with the selected preset.
      assert venue_likely.deltas == venue_minimum.deltas
      assert headcount(vm_likely, "Dinner").values == headcount(vm_minimum, "Dinner").values

      # The offer before → after line (computed at the selected preset only) does.
      assert [offer_likely] = venue_likely.offers
      assert [offer_minimum] = venue_minimum.offers
      assert offer_likely.label != offer_minimum.label

      # So do the formulas.
      assert venue_likely.delta_formula != venue_minimum.delta_formula
    end
  end

  # -- 4. summary wording, :no_budget, over-budget-after -------------------------------------

  describe "summary wording (BUD-20, DR-83)" do
    test "\"No changes yet\" with an empty draft" do
      snapshot = with_household(b1(), :likely)
      vm = build_vm(snapshot, %{})

      assert vm.summary == "No changes yet"
      refute vm.has_changes?
    end

    test "\"N changes for M people\", with overwritten RSVPs called out" do
      snapshot = with_household(b1(), :likely)
      draft = household_draft(:invited)
      vm = build_vm(snapshot, draft)

      assert vm.summary == "3 changes for 3 people"
      refute vm.apply.overwrites?

      # Force one shared Dinner guest's invitation to `:accepted` so declining them in
      # the draft counts as an overwritten RSVP (`DR-83`).
      snapshot2 = %{
        snapshot
        | invitations:
            Enum.map(snapshot.invitations, fn
              %{person_id: 1001} = inv -> %{inv | status: :accepted}
              inv -> inv
            end)
      }

      draft2 = Map.put(draft, 1001, %{@dinner_id => :declined})
      vm2 = build_vm(snapshot2, draft2)

      assert vm2.apply.overwrites?
      assert vm2.summary =~ "overwrites 1 RSVP"

      # A declined RSVP is an RSVP too: inviting someone who declined overwrites it.
      snapshot3 = %{
        snapshot
        | invitations:
            Enum.map(snapshot.invitations, fn
              %{person_id: 1001} = inv -> %{inv | status: :declined}
              inv -> inv
            end)
      }

      draft3 = Map.put(draft, 1001, %{@dinner_id => :invited})
      vm3 = build_vm(snapshot3, draft3)

      assert vm3.apply.overwrites?
      assert vm3.summary =~ "overwrites 1 RSVP"
    end
  end

  describe ":no_budget and over-budget-after wording" do
    test "Available after is :missing with no overall budget set" do
      snapshot = with_household(b1(), :likely)
      draft = household_draft()

      no_budget_snapshot = put_in(snapshot.settings.overall_budget, nil)
      vm = build_vm(no_budget_snapshot, draft)

      assert vm.overall.available_after == :missing
      refute vm.overall.over_budget_after?
    end

    test "over_budget_after? and its text when the after-forecast exceeds a tight budget" do
      snapshot = with_household(b1(), :likely)
      draft = household_draft()

      tight_snapshot = put_in(snapshot.settings.overall_budget, WeddingPlanner.Money.new(1))
      vm = build_vm(tight_snapshot, draft)

      assert vm.overall.over_budget_after?
      assert vm.overall.over_budget_text =~ "€"
    end
  end
end
