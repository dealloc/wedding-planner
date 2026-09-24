defmodule WeddingPlanner.Valuation.HeadcountTest do
  @moduledoc """
  `WeddingPlanner.Valuation.Headcount.evaluate/3` (`docs/modules/headcount.md`,
  `HC-01`…`HC-05`, `DR-48`), `counted/3` and `explain/3` (`NFR-32`, `HC-08`, `DR-55`) and
  `WeddingPlanner.Valuation.Preset.defaults/0` (`HC-06`, `DR-47`) over in-memory snapshots
  — no database, no sandbox (`NFR-41`).

  Normative examples `H1`–`H4` and `G4` are tagged `@tag example: "<id>"`. The property
  tests at the bottom compare the engine with a brute-force oracle written here, which
  shares no code with it: it re-derives every effective status by scanning the invitation
  and opt-out lists and reads a +1's inherited fields straight off its host.
  """
  use ExUnit.Case, async: true

  alias WeddingPlanner.Events.Event
  alias WeddingPlanner.Guests.Person
  alias WeddingPlanner.Invitations.Invitation
  alias WeddingPlanner.Invitations.PlusOneOptOut
  alias WeddingPlanner.Valuation.Formula
  alias WeddingPlanner.Valuation.Formula.Step
  alias WeddingPlanner.Valuation.Headcount
  alias WeddingPlanner.Valuation.Preset
  alias WeddingPlanner.Valuation.Snapshot

  @dinner %Event{id: 1, name: "Dinner", sort_order: 0}

  # -- helpers -------------------------------------------------------------------------------

  defp person(id, attrs \\ []), do: struct!(%Person{id: id}, attrs)

  defp plus_one(id, host_id, plus_one_status, attrs \\ []) do
    person(id, [host_id: host_id, plus_one_status: plus_one_status] ++ attrs)
  end

  defp invitation(id, person_id, event_id, status) do
    %Invitation{id: id, person_id: person_id, event_id: event_id, status: status}
  end

  defp opt_out(id, person_id, event_id) do
    %PlusOneOptOut{id: id, person_id: person_id, event_id: event_id}
  end

  defp counts(adults, children),
    do: %{adults: adults, children: children, total: adults + children}

  defp preset(attrs), do: struct!(%Preset{name: "ad hoc"}, Enum.map(attrs, &to_set/1))
  defp to_set({key, values}), do: {key, MapSet.new(values)}

  # Minimum, Likely and Maximum for `event`, in that order.
  defp defaults(snapshot, event) do
    Enum.map(Preset.defaults(), &Headcount.evaluate(snapshot, &1, event))
  end

  defp default_preset(name), do: Enum.find(Preset.defaults(), &(&1.name == name))

  # -- Preset.defaults/0 ---------------------------------------------------------------------

  describe "Preset.defaults/0 (HC-06, D-19, DR-47, DR-53)" do
    test "is the HC-06 table: Minimum, Likely, Maximum over planned/invited/accepted, each with its role" do
      statuses = MapSet.new([:planned, :invited, :accepted])

      assert Preset.defaults() == [
               %Preset{
                 id: nil,
                 name: "Minimum",
                 invitation_statuses: statuses,
                 certainties: MapSet.new([:certain]),
                 want_tiers: MapSet.new(),
                 age_categories: MapSet.new(),
                 group_ids: MapSet.new(),
                 role: :minimum
               },
               %Preset{
                 id: nil,
                 name: "Likely",
                 invitation_statuses: statuses,
                 certainties: MapSet.new([:certain, :likely]),
                 want_tiers: MapSet.new(),
                 age_categories: MapSet.new(),
                 group_ids: MapSet.new(),
                 role: :likely
               },
               %Preset{
                 id: nil,
                 name: "Maximum",
                 invitation_statuses: statuses,
                 certainties: MapSet.new(),
                 want_tiers: MapSet.new(),
                 age_categories: MapSet.new(),
                 group_ids: MapSet.new(),
                 role: :maximum
               }
             ]
    end

    test "an ad hoc preset has no id" do
      assert %Preset{name: "ad hoc"}.id == nil
    end
  end

  # -- normative examples --------------------------------------------------------------------

  # H1: 4 accepted (one of each certainty plus a second uncertain — "any certainty"),
  # 3 invited + certain, 2 invited + likely, 1 planned + uncertain. Persons 4, 9 and 10 are
  # children so the adult/child split is exercised too.
  defp h1_snapshot do
    rows = [
      {1, :accepted, :certain, :adult},
      {2, :accepted, :likely, :adult},
      {3, :accepted, :uncertain, :adult},
      {4, :accepted, :uncertain, :child},
      {5, :invited, :certain, :adult},
      {6, :invited, :certain, :adult},
      {7, :invited, :certain, :adult},
      {8, :invited, :likely, :adult},
      {9, :invited, :likely, :child},
      {10, :planned, :uncertain, :child}
    ]

    %Snapshot{
      events: [@dinner],
      persons: for({id, _, c, age} <- rows, do: person(id, certainty: c, age_category: age)),
      invitations:
        for({id, status, _, _} <- rows, do: invitation(100 + id, id, @dinner.id, status))
    }
  end

  # H2/H3: the +1 of person 3 (accepted, stored *uncertain* — so only HC-04 through the
  # host can make a confirmed +1 certain). Its own certainty/want tier columns are set to
  # values the engine must never read (DR-32).
  defp h1_with_plus_one(plus_one_status) do
    snapshot = h1_snapshot()
    guest = plus_one(11, 3, plus_one_status, age_category: :adult, certainty: :certain)
    %{snapshot | persons: snapshot.persons ++ [guest]}
  end

  describe "normative examples" do
    @tag example: "H1"
    test "H1: Minimum 7, Likely 9, Maximum 10" do
      assert defaults(h1_snapshot(), @dinner) == [counts(6, 1), counts(7, 2), counts(7, 3)]
    end

    @tag example: "H2"
    test "H2: a confirmed adult +1 of an accepted person adds 1 to every preset: 8 / 10 / 11" do
      assert defaults(h1_with_plus_one(:confirmed), @dinner) ==
               [counts(7, 1), counts(8, 2), counts(8, 3)]
    end

    @tag example: "H3"
    test "H3: that +1 possible instead adds 1 to Maximum only: 7 / 9 / 11" do
      assert defaults(h1_with_plus_one(:possible), @dinner) ==
               [counts(6, 1), counts(7, 2), counts(8, 3)]
    end

    @tag example: "H4"
    test "H4: a person with no invitation to Dinner counts in no preset, whatever the want tier" do
      party = %Event{id: 2, name: "Party", sort_order: 1}
      everything = %Preset{name: "Everything"}

      for want_tier <- [:yes, :maybe, :no, :obligated],
          certainty <- [:certain, :likely, :uncertain],
          age <- [:adult, :child] do
        # Invited to another event, to make sure "not invited" is per event.
        snapshot = %Snapshot{
          events: [@dinner, party],
          persons: [person(1, want_tier: want_tier, certainty: certainty, age_category: age)],
          invitations: [invitation(10, 1, party.id, :accepted)]
        }

        assert defaults(snapshot, @dinner) == [counts(0, 0), counts(0, 0), counts(0, 0)]
        # Not even a preset with every criterion empty counts them (DR-48).
        assert Headcount.evaluate(snapshot, everything, @dinner) == counts(0, 0)
      end
    end

    @tag example: "G4"
    test "G4: Ben's possible +1 is in Maximum only; once confirmed, in Likely and Maximum" do
      ben = person(1, certainty: :likely)

      snapshot = fn status ->
        %Snapshot{
          events: [@dinner],
          persons: [ben, plus_one(2, 1, status)],
          invitations: [invitation(10, 1, @dinner.id, :invited)]
        }
      end

      assert defaults(snapshot.(:possible), @dinner) == [counts(0, 0), counts(1, 0), counts(2, 0)]

      assert defaults(snapshot.(:confirmed), @dinner) == [
               counts(0, 0),
               counts(2, 0),
               counts(2, 0)
             ]
    end
  end

  # -- HC-04 ---------------------------------------------------------------------------------

  describe "HC-04 effective certainty" do
    test "declined is never counted, even by a preset that allows :declined with no certainty criterion" do
      snapshot = %Snapshot{
        events: [@dinner],
        persons: [person(1, certainty: :certain), person(2)],
        invitations: [
          invitation(10, 1, @dinner.id, :declined),
          invitation(11, 2, @dinner.id, :invited)
        ]
      }

      declined_allowed = preset(invitation_statuses: [:declined])
      all_statuses = preset(invitation_statuses: [:planned, :invited, :accepted, :declined])

      assert Headcount.evaluate(snapshot, declined_allowed, @dinner) == counts(0, 0)
      assert Headcount.evaluate(snapshot, all_statuses, @dinner) == counts(1, 0)
      assert Headcount.evaluate(snapshot, %Preset{name: "Everything"}, @dinner) == counts(1, 0)
    end

    test "an accepted person stored as uncertain counts in Minimum" do
      snapshot = %Snapshot{
        events: [@dinner],
        persons: [person(1, certainty: :uncertain)],
        invitations: [invitation(10, 1, @dinner.id, :accepted)]
      }

      assert Headcount.evaluate(snapshot, default_preset("Minimum"), @dinner) == counts(1, 0)

      assert Headcount.evaluate(snapshot, preset(certainties: [:uncertain]), @dinner) ==
               counts(0, 0)
    end
  end

  # -- HC-05 ---------------------------------------------------------------------------------

  describe "HC-05 +1s" do
    defp host_and_guest(host_status, host_attrs, guest_attrs, opt_outs \\ []) do
      invitations =
        if host_status == :not_invited,
          do: [],
          else: [invitation(10, 1, @dinner.id, host_status)]

      %Snapshot{
        events: [@dinner],
        persons: [person(1, host_attrs), plus_one(2, 1, :confirmed, guest_attrs)],
        invitations: invitations,
        plus_one_opt_outs: opt_outs
      }
    end

    test "a +1 is evaluated with its host's invitation status" do
      for status <- [:planned, :invited, :accepted] do
        snapshot = host_and_guest(status, [], [])

        assert Headcount.evaluate(snapshot, preset(invitation_statuses: [status]), @dinner) ==
                 counts(2, 0)

        others = [:planned, :invited, :accepted] -- [status]

        assert Headcount.evaluate(snapshot, preset(invitation_statuses: others), @dinner) ==
                 counts(0, 0)
      end
    end

    test "an opted-out +1 is not counted while its host is" do
      snapshot = host_and_guest(:accepted, [], [], [opt_out(20, 2, @dinner.id)])

      assert defaults(snapshot, @dinner) == [counts(1, 0), counts(1, 0), counts(1, 0)]
    end

    test "a +1 of a declining host is not counted, even with no opt-out (G3's case)" do
      snapshot = host_and_guest(:declined, [], [])

      assert defaults(snapshot, @dinner) == [counts(0, 0), counts(0, 0), counts(0, 0)]
      assert Headcount.evaluate(snapshot, %Preset{name: "Everything"}, @dinner) == counts(0, 0)
    end

    test "a +1 of a host who is not invited is not counted, even with an opt-out row" do
      snapshot = host_and_guest(:not_invited, [], [], [opt_out(20, 2, @dinner.id)])

      assert defaults(snapshot, @dinner) == [counts(0, 0), counts(0, 0), counts(0, 0)]

      assert Headcount.evaluate(snapshot, %Preset{name: "Everything"}, @dinner) == counts(0, 0)

      assert Headcount.evaluate(snapshot, preset(invitation_statuses: [:declined]), @dinner) ==
               counts(0, 0)
    end

    test "a possible +1 of an accepted, certain host stays uncertain: Maximum only" do
      snapshot = %Snapshot{
        events: [@dinner],
        persons: [person(1, certainty: :certain), plus_one(2, 1, :possible)],
        invitations: [invitation(10, 1, @dinner.id, :accepted)]
      }

      assert defaults(snapshot, @dinner) == [counts(1, 0), counts(1, 0), counts(2, 0)]

      assert Headcount.evaluate(snapshot, preset(certainties: [:uncertain]), @dinner) ==
               counts(1, 0)
    end

    test "a confirmed +1 of an accepted host is certain through the host (HC-04 through the host)" do
      snapshot = host_and_guest(:accepted, [certainty: :uncertain], certainty: :uncertain)

      assert Headcount.evaluate(snapshot, preset(certainties: [:certain]), @dinner) ==
               counts(2, 0)
    end

    test "a +1 is evaluated with its host's want tier; its own want tier column is never read" do
      snapshot = host_and_guest(:invited, [want_tier: :maybe], want_tier: :no)

      assert Headcount.evaluate(snapshot, preset(want_tiers: [:maybe]), @dinner) == counts(2, 0)
      assert Headcount.evaluate(snapshot, preset(want_tiers: [:no]), @dinner) == counts(0, 0)
    end

    test "a +1 is evaluated with its host's certainty; its own certainty column is never read" do
      snapshot = host_and_guest(:invited, [certainty: :likely], certainty: :certain)

      assert defaults(snapshot, @dinner) == [counts(0, 0), counts(2, 0), counts(2, 0)]
    end

    test "a +1 is evaluated under its host's group; its own group column is never read" do
      snapshot = host_and_guest(:invited, [group_id: 7], group_id: 99)

      assert Headcount.evaluate(snapshot, preset(group_ids: [7]), @dinner) == counts(2, 0)
      assert Headcount.evaluate(snapshot, preset(group_ids: [99]), @dinner) == counts(0, 0)
    end

    test "a +1's own age category decides adult vs child" do
      snapshot = host_and_guest(:invited, [age_category: :adult], age_category: :child)

      assert Headcount.evaluate(snapshot, default_preset("Maximum"), @dinner) == counts(1, 1)

      assert Headcount.evaluate(snapshot, preset(age_categories: [:child]), @dinner) ==
               counts(0, 1)

      snapshot = host_and_guest(:invited, [age_category: :child], age_category: :adult)

      assert Headcount.evaluate(snapshot, preset(age_categories: [:adult]), @dinner) ==
               counts(1, 0)
    end
  end

  # -- HC-02 ---------------------------------------------------------------------------------

  describe "HC-02 criteria" do
    # p1 invited/certain/yes/adult/group 1; p2 planned/likely/maybe/child/group 2;
    # p3 accepted (stored uncertain, effectively certain)/no/adult/ungrouped;
    # p4 invited/uncertain/obligated/child/group 1; p5 declined; p6 not invited.
    defp criteria_snapshot do
      %Snapshot{
        events: [@dinner],
        persons: [
          person(1, certainty: :certain, want_tier: :yes, age_category: :adult, group_id: 1),
          person(2, certainty: :likely, want_tier: :maybe, age_category: :child, group_id: 2),
          person(3, certainty: :uncertain, want_tier: :no, age_category: :adult, group_id: nil),
          person(4,
            certainty: :uncertain,
            want_tier: :obligated,
            age_category: :child,
            group_id: 1
          ),
          person(5, certainty: :certain, want_tier: :yes, age_category: :adult, group_id: 1),
          person(6, certainty: :certain, want_tier: :yes, age_category: :adult, group_id: 1)
        ],
        invitations: [
          invitation(11, 1, @dinner.id, :invited),
          invitation(12, 2, @dinner.id, :planned),
          invitation(13, 3, @dinner.id, :accepted),
          invitation(14, 4, @dinner.id, :invited),
          invitation(15, 5, @dinner.id, :declined)
        ]
      }
    end

    defp evaluate_criteria(attrs),
      do: Headcount.evaluate(criteria_snapshot(), preset(attrs), @dinner)

    test "a preset with every criterion empty counts exactly the planned/invited/accepted persons" do
      assert evaluate_criteria([]) == counts(2, 2)
    end

    test "the status criterion restricts on its own" do
      assert evaluate_criteria(invitation_statuses: [:invited]) == counts(1, 1)
      assert evaluate_criteria(invitation_statuses: [:planned, :accepted]) == counts(1, 1)
    end

    test "the certainty criterion restricts on its own, on effective certainty" do
      assert evaluate_criteria(certainties: [:certain]) == counts(2, 0)
      assert evaluate_criteria(certainties: [:uncertain]) == counts(0, 1)
    end

    test "the want tier criterion restricts on its own" do
      assert evaluate_criteria(want_tiers: [:maybe, :obligated]) == counts(0, 2)
      assert evaluate_criteria(want_tiers: [:yes]) == counts(1, 0)
    end

    test "the age category criterion restricts on its own" do
      assert evaluate_criteria(age_categories: [:child]) == counts(0, 2)
      assert evaluate_criteria(age_categories: [:adult]) == counts(2, 0)
    end

    test "the group criterion restricts on its own and excludes ungrouped persons" do
      assert evaluate_criteria(group_ids: [1]) == counts(1, 1)
      assert evaluate_criteria(group_ids: [1, 2]) == counts(1, 2)
    end

    test "criteria combine: a person must pass every non-empty one" do
      assert evaluate_criteria(invitation_statuses: [:invited], age_categories: [:child]) ==
               counts(0, 1)

      assert evaluate_criteria(group_ids: [1], certainties: [:certain], want_tiers: [:yes]) ==
               counts(1, 0)

      assert evaluate_criteria(group_ids: [2], age_categories: [:adult]) == counts(0, 0)
    end
  end

  # -- HC-03 ---------------------------------------------------------------------------------

  describe "HC-03 :all_events" do
    defp three_events do
      [
        %Event{id: 1, name: "Ceremony", sort_order: 0},
        %Event{id: 2, name: "Dinner", sort_order: 1},
        %Event{id: 3, name: "Party", sort_order: 2}
      ]
    end

    test "a person counted for three events contributes 1; one counted for none contributes 0" do
      snapshot = %Snapshot{
        events: three_events(),
        persons: [
          person(1, age_category: :adult),
          person(2, age_category: :child),
          person(3, age_category: :adult),
          person(4, age_category: :child)
        ],
        invitations:
          for(event_id <- [1, 2, 3], do: invitation(10 + event_id, 1, event_id, :invited)) ++
            [
              invitation(21, 2, 3, :planned),
              invitation(22, 3, 1, :declined),
              invitation(23, 3, 2, :declined)
            ]
      }

      maximum = default_preset("Maximum")

      assert Enum.map(three_events(), &Headcount.evaluate(snapshot, maximum, &1)) ==
               [counts(1, 0), counts(1, 0), counts(1, 1)]

      assert Headcount.evaluate(snapshot, maximum, :all_events) == counts(1, 1)
    end

    test "counts a person by the preset, not by attendance: a planned invitation counts" do
      snapshot = %Snapshot{
        events: three_events(),
        persons: [person(1, certainty: :certain)],
        invitations: [invitation(10, 1, 2, :planned)]
      }

      assert Headcount.evaluate(snapshot, default_preset("Minimum"), :all_events) == counts(1, 0)
    end

    test "a +1 counted for several events contributes 1 and is split by its own age" do
      snapshot = %Snapshot{
        events: three_events(),
        persons: [person(1), plus_one(2, 1, :confirmed, age_category: :child)],
        invitations:
          for(event_id <- [1, 2, 3], do: invitation(10 + event_id, 1, event_id, :accepted)),
        plus_one_opt_outs: [opt_out(30, 2, 1)]
      }

      assert Headcount.evaluate(snapshot, default_preset("Minimum"), :all_events) == counts(1, 1)
    end

    test "over a snapshot with no events it is all zeros" do
      snapshot = %Snapshot{
        events: [],
        persons: [person(1)],
        invitations: [invitation(10, 1, 1, :accepted)]
      }

      assert Headcount.evaluate(snapshot, %Preset{name: "Everything"}, :all_events) ==
               counts(0, 0)

      assert Headcount.evaluate(%Snapshot{}, default_preset("Maximum"), :all_events) ==
               counts(0, 0)
    end
  end

  # -- ids and what-ifs ----------------------------------------------------------------------

  describe "ids and what-ifs" do
    test "works with make_ref/0 ids for persons, events and invitations (what-if rows)" do
      [host, guest, other] = [make_ref(), make_ref(), make_ref()]
      event = %Event{id: make_ref(), name: "Brunch"}

      snapshot = %Snapshot{
        events: [event],
        persons: [
          person(host, certainty: :likely),
          plus_one(guest, host, :confirmed, age_category: :child),
          person(other, certainty: :certain)
        ],
        invitations: [invitation(make_ref(), host, event.id, :invited)]
      }

      assert defaults(snapshot, event) == [counts(0, 0), counts(1, 1), counts(1, 1)]
      assert Headcount.evaluate(snapshot, default_preset("Likely"), :all_events) == counts(1, 1)
    end

    test "evaluating a Snapshot.apply/2 what-if changes exactly what the change implies" do
      snapshot = h1_snapshot()
      before = defaults(snapshot, @dinner)

      # Person 8 (invited + likely) declines.
      declined = Snapshot.apply(snapshot, {:put, :invitations, invitation(108, 8, 1, :declined)})

      assert defaults(declined, @dinner) == [counts(6, 1), counts(6, 2), counts(6, 3)]

      # A hypothetical new, planned, certain guest.
      id = make_ref()

      added =
        Snapshot.apply(snapshot, [
          {:put, :persons, person(id, certainty: :certain)},
          {:put, :invitations, invitation(make_ref(), id, 1, :planned)}
        ])

      assert defaults(added, @dinner) == [counts(7, 1), counts(8, 2), counts(8, 3)]

      # The original snapshot is untouched and evaluates as before.
      assert snapshot == h1_snapshot()
      assert defaults(snapshot, @dinner) == before
    end

    test "a +1 whose host is missing from the snapshot raises (a caller bug)" do
      snapshot = %Snapshot{events: [@dinner], persons: [plus_one(2, 1, :confirmed)]}

      assert_raise KeyError, fn ->
        Headcount.evaluate(snapshot, default_preset("Likely"), @dinner)
      end
    end
  end

  # -- counted/3 and explain/3 (NFR-32, HC-08, DR-55) ----------------------------------------

  defp preset_step(name), do: %Step{label: "Headcount preset", value: {:preset, name}}

  defp status_step(name, adults, children) do
    %Step{
      label: [
        name <> " — ",
        {:count, adults},
        " #{noun(adults, "adult", "adults")} + ",
        {:count, children},
        " #{noun(children, "child", "children")}"
      ],
      value: {:count, adults + children}
    }
  end

  # Task 71: the noun agrees with its own count (singular at exactly 1, plural
  # otherwise, including 0) — mirrors `Headcount`'s own private `noun/3`.
  defp noun(1, singular, _plural), do: singular
  defp noun(_n, _singular, plural), do: plural

  defp triples(counted), do: Enum.map(counted, &{&1.person.id, &1.status, &1.certainty})

  describe "explain/3 for an event (NFR-32, HC-08, DR-55)" do
    # The H1 fixture as built: accepted 1, 2, 3 (adults) + 4 (child); invited 5, 6, 7 (certain
    # adults), 8 (likely adult), 9 (likely child); planned 10 (uncertain child).
    test "H1 under Likely: the preset, accepted 3 + 1, invited 4 + 1, no planned step; total 9" do
      assert Headcount.explain(h1_snapshot(), default_preset("Likely"), @dinner) == %Formula{
               label: "Headcount",
               steps: [
                 preset_step("Likely"),
                 status_step("Accepted", 3, 1),
                 status_step("Invited", 4, 1)
               ],
               total: {:count, 9}
             }
    end

    test "H1 under Maximum: the uncertain planned child adds a Planned step; total 10" do
      assert Headcount.explain(h1_snapshot(), default_preset("Maximum"), @dinner) == %Formula{
               label: "Headcount",
               steps: [
                 preset_step("Maximum"),
                 status_step("Accepted", 3, 1),
                 status_step("Invited", 4, 1),
                 status_step("Planned", 0, 1)
               ],
               total: {:count, 10}
             }
    end

    test "HC-08: the first step always names the preset used, for every preset and target" do
      snapshot = h1_snapshot()
      presets = [preset(group_ids: [42]) | Preset.defaults()]

      for preset <- presets, target <- [@dinner, :all_events] do
        assert [first | _] = Headcount.explain(snapshot, preset, target).steps
        assert first == preset_step(preset.name)
      end
    end

    test "a preset that counts nobody explains as the preset step alone, total 0" do
      assert Headcount.explain(h1_snapshot(), preset(group_ids: [42]), @dinner) == %Formula{
               label: "Headcount",
               steps: [preset_step("ad hoc")],
               total: {:count, 0}
             }

      assert Headcount.explain(%Snapshot{}, default_preset("Likely"), :all_events) == %Formula{
               label: "Distinct persons",
               steps: [preset_step("Likely")],
               total: {:count, 0}
             }
    end
  end

  describe "explain/3 noun agreement for 0/1/2 adults and children (task 71)" do
    defp accepted_snapshot(adults, children) do
      adult_rows = for id <- 1..adults//1, do: {id, :adult}
      child_rows = for id <- (adults + 1)..(adults + children)//1, do: {id, :child}
      rows = adult_rows ++ child_rows

      %Snapshot{
        events: [@dinner],
        persons: for({id, age} <- rows, do: person(id, certainty: :certain, age_category: age)),
        invitations: for({id, _age} <- rows, do: invitation(100 + id, id, @dinner.id, :accepted))
      }
    end

    test "1 adult, 0 children: \"1 adult + 0 children\"" do
      assert Headcount.explain(accepted_snapshot(1, 0), default_preset("Likely"), @dinner) ==
               %Formula{
                 label: "Headcount",
                 steps: [
                   preset_step("Likely"),
                   %Step{
                     label: ["Accepted — ", {:count, 1}, " adult + ", {:count, 0}, " children"],
                     value: {:count, 1}
                   }
                 ],
                 total: {:count, 1}
               }
    end

    test "0 adults, 1 child: \"0 adults + 1 child\"" do
      assert Headcount.explain(accepted_snapshot(0, 1), default_preset("Likely"), @dinner) ==
               %Formula{
                 label: "Headcount",
                 steps: [
                   preset_step("Likely"),
                   %Step{
                     label: ["Accepted — ", {:count, 0}, " adults + ", {:count, 1}, " child"],
                     value: {:count, 1}
                   }
                 ],
                 total: {:count, 1}
               }
    end

    test "2 adults, 2 children: \"2 adults + 2 children\" (already plural, unaffected)" do
      assert Headcount.explain(accepted_snapshot(2, 2), default_preset("Likely"), @dinner) ==
               %Formula{
                 label: "Headcount",
                 steps: [
                   preset_step("Likely"),
                   %Step{
                     label: ["Accepted — ", {:count, 2}, " adults + ", {:count, 2}, " children"],
                     value: {:count, 4}
                   }
                 ],
                 total: {:count, 4}
               }
    end
  end

  describe "counted/3 for an event (NFR-32, DR-55)" do
    test "H2 under Likely: everyone with the effective status and certainty, the +1 accepted and certain" do
      # Person 3 is stored uncertain and the +1 (11) is stored certain, but both are counted
      # as certain because the status is accepted (HC-04, through the host for the +1).
      assert h1_with_plus_one(:confirmed)
             |> Headcount.counted(default_preset("Likely"), @dinner)
             |> triples() == [
               {1, :accepted, :certain},
               {2, :accepted, :certain},
               {3, :accepted, :certain},
               {4, :accepted, :certain},
               {5, :invited, :certain},
               {6, :invited, :certain},
               {7, :invited, :certain},
               {8, :invited, :likely},
               {9, :invited, :likely},
               {11, :accepted, :certain}
             ]
    end

    test "H3: the possible +1 appears only under Maximum, as uncertain" do
      snapshot = h1_with_plus_one(:possible)

      for name <- ["Minimum", "Likely"] do
        ids =
          snapshot |> Headcount.counted(default_preset(name), @dinner) |> Enum.map(& &1.person.id)

        refute 11 in ids, "#{name} counts the possible +1"
      end

      assert [plus_one] =
               snapshot
               |> Headcount.counted(default_preset("Maximum"), @dinner)
               |> Enum.filter(&(&1.person.id == 11))

      assert %{person: %Person{id: 11}, status: :accepted, certainty: :uncertain} = plus_one
    end

    test "entries are the snapshot's own person structs, in snapshot.persons order" do
      snapshot = h1_with_plus_one(:confirmed)
      counted = Headcount.counted(snapshot, default_preset("Maximum"), @dinner)

      assert Enum.map(counted, & &1.person) == snapshot.persons
    end
  end

  describe "counted/3 and explain/3 for :all_events (HC-03, DR-55)" do
    defp two_events do
      [
        %Event{id: 1, name: "Ceremony", sort_order: 0},
        %Event{id: 2, name: "Dinner", sort_order: 1}
      ]
    end

    # Person 1 is counted for both events, person 2 for Dinner only, person 3 for neither.
    defp overlap_snapshot do
      %Snapshot{
        events: two_events(),
        persons: [person(1), person(2, age_category: :child), person(3)],
        invitations: [
          invitation(11, 1, 1, :invited),
          invitation(12, 1, 2, :accepted),
          invitation(22, 2, 2, :planned),
          invitation(31, 3, 1, :declined)
        ]
      }
    end

    test "a person counted for two events appears once, with both event ids" do
      [p1, p2, _p3] = overlap_snapshot().persons

      assert Headcount.counted(overlap_snapshot(), default_preset("Maximum"), :all_events) == [
               %{person: p1, event_ids: [1, 2]},
               %{person: p2, event_ids: [2]}
             ]
    end

    test "explain/3 lists each event's total and the overlap counted once" do
      assert Headcount.explain(overlap_snapshot(), default_preset("Maximum"), :all_events) ==
               %Formula{
                 label: "Distinct persons",
                 steps: [
                   preset_step("Maximum"),
                   %Step{label: "Ceremony", value: {:count, 1}},
                   %Step{label: "Dinner", value: {:count, 2}},
                   %Step{
                     label: "Counted for more than one event (each counted once)",
                     value: {:count, 1}
                   }
                 ],
                 total: {:count, 2}
               }
    end

    test "with no overlap there is no overlap step" do
      # Person 1's Dinner invitation is declined: now nobody is counted twice.
      snapshot =
        Snapshot.apply(overlap_snapshot(), {:put, :invitations, invitation(12, 1, 2, :declined)})

      assert Headcount.explain(snapshot, default_preset("Maximum"), :all_events) == %Formula{
               label: "Distinct persons",
               steps: [
                 preset_step("Maximum"),
                 %Step{label: "Ceremony", value: {:count, 1}},
                 %Step{label: "Dinner", value: {:count, 1}}
               ],
               total: {:count, 2}
             }
    end
  end

  # -- property tests (no new dependency; fixed :rand seeds) ---------------------------------

  @statuses [:planned, :invited, :accepted, :declined]
  @certainties [:certain, :likely, :uncertain]
  @want_tiers [:yes, :maybe, :no, :obligated]
  @ages [:adult, :child]
  @groups [1, 2, 3]

  describe "property: random snapshots" do
    @describetag :property

    test "evaluate/3 equals a brute-force oracle for every event and for :all_events" do
      seed = {53, 1, 7}
      :rand.seed(:exsss, seed)

      for iteration <- 1..400 do
        snapshot = random_snapshot()
        presets = Preset.defaults() ++ for(_ <- 1..4, do: random_preset())

        for preset <- presets do
          targets = snapshot.events ++ [:all_events]
          actual = Enum.map(targets, &Headcount.evaluate(snapshot, preset, &1))
          expected = Enum.map(targets, &oracle(snapshot, preset, &1))

          assert actual == expected, failure(seed, iteration, snapshot, preset: preset)
        end
      end
    end

    test "counted/3, evaluate/3 and explain/3 agree with each other and with the oracle (DR-55)" do
      seed = {59, 1, 23}
      :rand.seed(:exsss, seed)

      for iteration <- 1..300 do
        snapshot = random_snapshot()

        for preset <- Preset.defaults() ++ for(_ <- 1..3, do: random_preset()) do
          violations =
            Enum.flat_map(snapshot.events, &event_violations(snapshot, preset, &1)) ++
              all_events_violations(snapshot, preset)

          assert violations == [],
                 failure(seed, iteration, snapshot, preset: preset, violations: violations)
        end
      end
    end

    test "Minimum <= Likely <= Maximum, total = adults + children, and :all_events is bounded" do
      seed = {53, 2, 11}
      :rand.seed(:exsss, seed)

      for iteration <- 1..300 do
        snapshot = random_snapshot()
        preset = random_preset()

        violations =
          Enum.flat_map(snapshot.events, fn event ->
            [minimum, likely, maximum] = defaults(snapshot, event)

            monotone =
              for key <- [:adults, :children, :total],
                  not (minimum[key] <= likely[key] and likely[key] <= maximum[key]),
                  do: {:not_monotone, event.id, key, minimum, likely, maximum}

            sums =
              for counts <- [
                    minimum,
                    likely,
                    maximum,
                    Headcount.evaluate(snapshot, preset, event)
                  ],
                  counts.total != counts.adults + counts.children,
                  do: {:total_is_not_the_sum, event.id, counts}

            monotone ++ sums
          end)

        bounds =
          for preset <- [preset | Preset.defaults()] do
            per_event = Enum.map(snapshot.events, &Headcount.evaluate(snapshot, preset, &1).total)
            all = Headcount.evaluate(snapshot, preset, :all_events)

            cond do
              all.total != all.adults + all.children ->
                {:all_events_total_is_not_the_sum, all}

              Enum.any?(per_event, &(all.total < &1)) ->
                {:all_events_below_an_event, all, per_event}

              all.total > Enum.sum(per_event) ->
                {:all_events_above_the_sum, all, per_event}

              all.total > length(snapshot.persons) ->
                {:all_events_above_distinct_persons, all}

              true ->
                :ok
            end
          end

        violations = violations ++ Enum.reject(bounds, &(&1 == :ok))

        assert violations == [],
               failure(seed, iteration, snapshot, preset: preset, violations: violations)
      end
    end

    test "adding a :declined invitation for an uninvited person never changes any count" do
      seed = {53, 3, 13}
      :rand.seed(:exsss, seed)

      for iteration <- 1..300 do
        snapshot = random_snapshot()

        uninvited =
          for %Person{host_id: nil} = p <- snapshot.persons,
              event <- snapshot.events,
              not Enum.any?(
                snapshot.invitations,
                &(&1.person_id == p.id and &1.event_id == event.id)
              ),
              do: {p.id, event.id}

        if uninvited != [] do
          {person_id, event_id} = Enum.random(uninvited)

          changed =
            Snapshot.apply(
              snapshot,
              {:put, :invitations, invitation(make_ref(), person_id, event_id, :declined)}
            )

          presets = [random_preset() | Preset.defaults()]

          assert all_counts(changed, presets) == all_counts(snapshot, presets),
                 failure(seed, iteration, snapshot,
                   declined: {person_id, event_id},
                   presets: presets
                 )
        end
      end
    end

    test "adding an opt-out never increases any count" do
      seed = {53, 4, 17}
      :rand.seed(:exsss, seed)

      for iteration <- 1..300 do
        snapshot = random_snapshot()

        candidates =
          for %Person{host_id: host_id} = p <- snapshot.persons,
              host_id != nil,
              event <- snapshot.events,
              not Enum.any?(
                snapshot.plus_one_opt_outs,
                &(&1.person_id == p.id and &1.event_id == event.id)
              ),
              do: {p.id, event.id}

        if candidates != [] do
          {person_id, event_id} = Enum.random(candidates)

          changed =
            Snapshot.apply(
              snapshot,
              {:put, :plus_one_opt_outs, opt_out(make_ref(), person_id, event_id)}
            )

          presets = [random_preset() | Preset.defaults()]

          increases =
            for {old, new} <-
                  Enum.zip(all_counts(snapshot, presets), all_counts(changed, presets)),
                key <- [:adults, :children, :total],
                new[key] > old[key],
                do: {key, old, new}

          assert increases == [],
                 failure(seed, iteration, snapshot,
                   opt_out: {person_id, event_id},
                   presets: presets
                 )
        end
      end
    end
  end

  # Every DR-55 invariant for one event, as a list of violations (empty when all hold).
  defp event_violations(snapshot, preset, %Event{id: event_id} = event) do
    counted = Headcount.counted(snapshot, preset, event)
    counts = Headcount.evaluate(snapshot, preset, event)
    formula = Headcount.explain(snapshot, preset, event)
    [first | status_steps] = formula.steps
    adults = Enum.count(counted, &(&1.person.age_category == :adult))
    children = Enum.count(counted, &(&1.person.age_category == :child))

    expected =
      for p <- snapshot.persons,
          {status, certainty} <- [oracle_decide(snapshot, preset, p, event_id)],
          do: {p.id, status, certainty}

    checks = [
      {:length_is_not_the_total, length(counted) == counts.total},
      {:split_disagrees, {adults, children} == {counts.adults, counts.children}},
      {:preset_step_missing,
       first == %Step{label: "Headcount preset", value: {:preset, preset.name}}},
      {:explain_total_disagrees, formula.total == {:count, counts.total}},
      {:status_steps_do_not_sum,
       Enum.sum(for %Step{value: {:count, n}} <- status_steps, do: n) == counts.total},
      {:recorded_values_fail_the_preset,
       Enum.all?(counted, fn c ->
         c.status in [:planned, :invited, :accepted] and
           oracle_allows?(preset.invitation_statuses, c.status) and
           oracle_allows?(preset.certainties, c.certainty)
       end)},
      {:ids_differ_from_oracle,
       MapSet.new(counted, & &1.person.id) == MapSet.new(expected, &elem(&1, 0))},
      {:status_or_certainty_differs_from_oracle,
       Enum.map(counted, &{&1.person.id, &1.status, &1.certainty}) == expected}
    ]

    for {name, false} <- checks, do: {name, event_id, counted, counts, formula}
  end

  # Every DR-55 invariant for :all_events (HC-03), as a list of violations.
  defp all_events_violations(snapshot, preset) do
    counted = Headcount.counted(snapshot, preset, :all_events)
    counts = Headcount.evaluate(snapshot, preset, :all_events)
    formula = Headcount.explain(snapshot, preset, :all_events)
    adults = Enum.count(counted, &(&1.person.age_category == :adult))
    children = Enum.count(counted, &(&1.person.age_category == :child))

    expected =
      for p <- snapshot.persons,
          ids <- [for(e <- snapshot.events, oracle_counts?(snapshot, preset, p, e.id), do: e.id)],
          ids != [],
          do: {p.id, ids}

    per_event = Enum.map(snapshot.events, &Headcount.evaluate(snapshot, preset, &1).total)
    overlap = Enum.sum(per_event) - counts.total

    expected_steps =
      [%Step{label: "Headcount preset", value: {:preset, preset.name}}] ++
        Enum.zip_with(snapshot.events, per_event, &%Step{label: &1.name, value: {:count, &2}}) ++
        if overlap > 0,
          do: [
            %Step{
              label: "Counted for more than one event (each counted once)",
              value: {:count, overlap}
            }
          ],
          else: []

    checks = [
      {:length_is_not_the_total, length(counted) == counts.total},
      {:split_disagrees, {adults, children} == {counts.adults, counts.children}},
      {:ids_differ_from_oracle,
       MapSet.new(counted, & &1.person.id) == MapSet.new(expected, &elem(&1, 0))},
      {:event_ids_differ_from_oracle,
       Enum.map(counted, &{&1.person.id, &1.event_ids}) == expected},
      {:explain_disagrees,
       formula == %Formula{
         label: "Distinct persons",
         steps: expected_steps,
         total: {:count, counts.total}
       }}
    ]

    for {name, false} <- checks, do: {name, :all_events, counted, counts, formula}
  end

  defp all_counts(snapshot, presets) do
    for preset <- presets, target <- snapshot.events ++ [:all_events] do
      Headcount.evaluate(snapshot, preset, target)
    end
  end

  defp failure(seed, iteration, snapshot, extra) do
    "seed #{inspect(seed)}, iteration #{iteration}\n" <>
      "extra: #{inspect(extra, pretty: true)}\n" <>
      "snapshot: #{inspect(Map.take(snapshot, [:events, :persons, :invitations, :plus_one_opt_outs]), pretty: true, limit: :infinity)}"
  end

  # -- random generation ---------------------------------------------------------------------

  defp pick(list), do: Enum.at(list, :rand.uniform(length(list)) - 1)
  defp chance(p), do: :rand.uniform() < p

  # 0–40 persons, some of them +1s of random earlier hosts (possible or confirmed); every
  # person gets random own want tier/certainty/group columns, which for a +1 the engine must
  # never read. 1–4 events; each host × event has an invitation with probability 0.65 and a
  # random status; each +1 × event an opt-out with probability 0.3.
  defp random_snapshot do
    events =
      for id <- 1..:rand.uniform(4), do: %Event{id: id, name: "Event #{id}", sort_order: id}

    count = :rand.uniform(41) - 1

    persons =
      Enum.reduce(1..count//1, [], fn id, acc ->
        hosts = for %Person{host_id: nil} = p <- acc, do: p.id

        link =
          if hosts != [] and chance(0.3),
            do: [host_id: pick(hosts), plus_one_status: pick([:possible, :confirmed])],
            else: []

        attrs = [
          want_tier: pick(@want_tiers),
          certainty: pick(@certainties),
          age_category: pick(@ages),
          group_id: pick([nil | @groups])
        ]

        [person(id, link ++ attrs) | acc]
      end)
      |> Enum.reverse()

    invitations =
      for %Person{host_id: nil} = p <- persons, event <- events, chance(0.65) do
        invitation(make_ref(), p.id, event.id, pick(@statuses))
      end

    opt_outs =
      for %Person{host_id: host_id} = p <- persons,
          host_id != nil,
          event <- events,
          chance(0.3) do
        opt_out(make_ref(), p.id, event.id)
      end

    %Snapshot{
      events: events,
      persons: persons,
      invitations: Enum.shuffle(invitations),
      plus_one_opt_outs: Enum.shuffle(opt_outs)
    }
  end

  # Each criterion a random subset of its domain, often empty. The group domain includes an
  # id no person has.
  defp random_preset do
    subset = fn domain ->
      if chance(0.4), do: [], else: Enum.filter(domain, fn _ -> chance(0.5) end)
    end

    preset(
      invitation_statuses: subset.(@statuses),
      certainties: subset.(@certainties),
      want_tiers: subset.(@want_tiers),
      age_categories: subset.(@ages),
      group_ids: subset.([4 | @groups])
    )
  end

  # -- the oracle (shares no code with the engine) -------------------------------------------

  defp oracle(snapshot, preset, :all_events) do
    snapshot.persons
    |> Enum.filter(fn p ->
      Enum.any?(snapshot.events, &oracle_counts?(snapshot, preset, p, &1.id))
    end)
    |> oracle_tally()
  end

  defp oracle(snapshot, preset, %Event{id: event_id}) do
    snapshot.persons
    |> Enum.filter(&oracle_counts?(snapshot, preset, &1, event_id))
    |> oracle_tally()
  end

  defp oracle_tally(persons) do
    adults = Enum.count(persons, &(&1.age_category == :adult))
    children = Enum.count(persons, &(&1.age_category == :child))
    %{adults: adults, children: children, total: adults + children}
  end

  defp oracle_counts?(snapshot, preset, p, event_id),
    do: oracle_decide(snapshot, preset, p, event_id) != nil

  # `{effective_status, effective_certainty}` when `preset` counts `p` for `event_id`, else nil.
  defp oracle_decide(snapshot, preset, p, event_id) do
    status = oracle_status(snapshot, p, event_id)
    plus_one? = p.host_id != nil
    host = if plus_one?, do: Enum.find(snapshot.persons, &(&1.id == p.host_id))

    certainty =
      cond do
        plus_one? and p.plus_one_status == :possible -> :uncertain
        status == :accepted -> :certain
        plus_one? -> host.certainty
        true -> p.certainty
      end

    want_tier = if plus_one?, do: host.want_tier, else: p.want_tier
    group_id = if plus_one?, do: host.group_id, else: p.group_id

    counted? =
      status in [:planned, :invited, :accepted] and
        oracle_allows?(preset.invitation_statuses, status) and
        oracle_allows?(preset.certainties, certainty) and
        oracle_allows?(preset.want_tiers, want_tier) and
        oracle_allows?(preset.age_categories, p.age_category) and
        oracle_allows?(preset.group_ids, group_id)

    if counted?, do: {status, certainty}
  end

  defp oracle_allows?(set, value), do: Enum.empty?(set) or Enum.member?(set, value)

  # PER-13/14 by scanning the raw lists.
  defp oracle_status(snapshot, p, event_id) do
    own = fn person_id ->
      case Enum.filter(
             snapshot.invitations,
             &(&1.person_id == person_id and &1.event_id == event_id)
           ) do
        [] -> :not_invited
        [row] -> row.status
      end
    end

    if p.host_id == nil do
      own.(p.id)
    else
      host_status = own.(p.host_id)

      opted_out =
        Enum.any?(snapshot.plus_one_opt_outs, &(&1.person_id == p.id and &1.event_id == event_id))

      cond do
        host_status == :not_invited -> :not_invited
        host_status == :declined -> :declined
        opted_out -> :declined
        true -> host_status
      end
    end
  end
end
