defmodule WeddingPlanner.SeatingTest do
  @moduledoc """
  `docs/modules/seating.md` SEAT-20, SEAT-21, SEAT-30, SEAT-31, SEAT-35, SEAT-80,
  SEAT-81, `XC-10`, `XC-12`, `XC-40` — the seating context's circles, memberships and
  rules.
  """
  use WeddingPlanner.DataCase, async: true

  alias WeddingPlanner.Accounts.Scope
  alias WeddingPlanner.Accounts.User
  alias WeddingPlanner.Guests
  alias WeddingPlanner.Log.EntityRef
  alias WeddingPlanner.Log.Entry
  alias WeddingPlanner.Realtime
  alias WeddingPlanner.Seating
  alias WeddingPlanner.Seating.Circle
  alias WeddingPlanner.Seating.CircleMembership
  alias WeddingPlanner.Seating.Rule

  setup do
    user = insert_user!("Wannes")
    scope = Scope.for_user(user)
    {:ok, jan} = Guests.create_person(scope, %{"first_name" => "Jan", "last_name" => "Peeters"})
    {:ok, mia} = Guests.create_person(scope, %{"first_name" => "Mia", "last_name" => "Peeters"})
    %{scope: scope, jan: jan, mia: mia}
  end

  defp insert_user!(display_name) do
    %User{} |> User.changeset(%{display_name: display_name}) |> Repo.insert!()
  end

  defp descriptions(type) do
    Entry
    |> where([e], e.entity_type == ^type)
    |> order_by(:id)
    |> select([e], e.description)
    |> Repo.all()
  end

  defp circle!(scope, name \\ "Uni friends", cohesion \\ "keep_together") do
    {:ok, circle} = Seating.create_circle(scope, %{"name" => name, "cohesion" => cohesion})
    circle
  end

  describe "circles (SEAT-20, SEAT-21)" do
    test "create, log and broadcast", %{scope: scope} do
      Realtime.subscribe(:circle)
      circle = circle!(scope)

      assert circle.cohesion == :keep_together
      assert circle.members == []
      assert descriptions("circle") == ["Wannes created circle 'Uni friends' (keep together)"]
      assert_receive {Realtime, :circle, {:created, %{id: id}}} when id == circle.id
    end

    test "names are required and unique", %{scope: scope} do
      _ = circle!(scope)

      assert {:error, changeset} =
               Seating.create_circle(scope, %{"name" => " ", "cohesion" => "keep_together"})

      assert "can't be blank" in errors_on(changeset).name

      assert {:error, changeset} = Seating.create_circle(scope, %{"name" => "Uni friends"})
      assert "another circle already has this name" in errors_on(changeset).name
    end

    test "renaming and changing cohesion each log one entry", %{scope: scope} do
      circle = circle!(scope)

      {:ok, updated} =
        Seating.update_circle(scope, circle, %{"name" => "Uni", "cohesion" => "know_each_other"})

      assert updated.name == "Uni"

      assert descriptions("circle") -- ["Wannes created circle 'Uni friends' (keep together)"] ==
               [
                 "Wannes renamed circle 'Uni friends' to 'Uni'",
                 "Wannes changed the cohesion of 'Uni': keep together → know each other"
               ]
    end

    test "list_circles sorts by name and preloads members", %{scope: scope, jan: jan} do
      zeta = circle!(scope, "Zeta")
      {:ok, _} = Seating.add_member(scope, zeta, jan)
      _ = circle!(scope, "alpha")

      assert [%{name: "alpha"}, %{name: "Wedding party"}, %{name: "Zeta", members: [%{id: id}]}] =
               Seating.list_circles()

      assert id == jan.id
    end
  end

  describe "membership" do
    test "a person can be in several circles; adding twice is a no-op", %{scope: scope, jan: jan} do
      uni = circle!(scope, "Uni")
      work = circle!(scope, "Work")

      {:ok, _} = Seating.add_member(scope, uni, jan)
      {:ok, uni} = Seating.add_member(scope, uni, jan)
      {:ok, _} = Seating.add_member(scope, work, jan)

      assert Enum.map(uni.members, & &1.id) == [jan.id]
      assert Repo.aggregate(CircleMembership, :count) == 2
      assert Enum.count(descriptions("circle"), &(&1 =~ "added 'Jan Peeters'")) == 2
    end

    test "removing logs; removing a non-member writes nothing", %{
      scope: scope,
      jan: jan,
      mia: mia
    } do
      circle = circle!(scope)
      {:ok, _} = Seating.add_member(scope, circle, jan)
      before = Repo.aggregate(Entry, :count)

      {:ok, _} = Seating.remove_member(scope, circle, mia)
      assert Repo.aggregate(Entry, :count) == before

      {:ok, circle} = Seating.remove_member(scope, circle, jan)
      assert circle.members == []

      assert List.last(descriptions("circle")) ==
               "Wannes removed 'Jan Peeters' from 'Uni friends'"
    end

    test "adding a group is one bulk action that skips existing members (XC-12)",
         %{scope: scope, jan: jan, mia: mia} do
      {:ok, family} = Guests.create_group(scope, %{"name" => "Family Peeters"})
      {:ok, jan} = Guests.update_person(scope, jan, %{"group_id" => family.id})
      {:ok, _mia} = Guests.update_person(scope, mia, %{"group_id" => family.id})
      circle = circle!(scope)
      {:ok, _} = Seating.add_member(scope, circle, jan)

      {:ok, circle} = Seating.add_group_members(scope, circle, family)

      assert circle.members |> Enum.map(& &1.first_name) |> Enum.sort() == ["Jan", "Mia"]

      summary = Repo.one!(from e in Entry, where: is_nil(e.entity_type))

      assert summary.description ==
               "Wannes added 1 person from group 'Family Peeters' to 'Uni friends'"

      assert [%{description: "Wannes added 'Mia Peeters' to 'Uni friends'"}] =
               Repo.all(from e in Entry, where: e.parent_id == ^summary.id)
    end
  end

  describe "rules (SEAT-30, SEAT-31)" do
    test "create, describe, log and broadcast", %{scope: scope, jan: jan, mia: mia} do
      Realtime.subscribe(:seating_rule)

      {:ok, rule} =
        Seating.create_rule(scope, %{
          "subject" => "person:#{mia.id}",
          "object" => "person:#{jan.id}",
          "relation" => "never_with",
          "reason" => "  divorce "
        })

      assert rule.reason == "divorce"
      assert Seating.describe(rule) == "'Jan Peeters' never with 'Mia Peeters'"

      assert descriptions("seating_rule") == [
               "Wannes added the rule 'Jan Peeters' never with 'Mia Peeters' — divorce"
             ]

      assert_receive {Realtime, :seating_rule, {:created, %Rule{}}}
    end

    test "a rule is symmetric: the reverse pair is refused", %{scope: scope, jan: jan, mia: mia} do
      attrs = %{
        "subject" => "person:#{jan.id}",
        "object" => "person:#{mia.id}",
        "relation" => "seat_with"
      }

      {:ok, _} = Seating.create_rule(scope, attrs)

      assert {:error, changeset} =
               Seating.create_rule(scope, %{
                 attrs
                 | "subject" => attrs["object"],
                   "object" => attrs["subject"]
               })

      assert errors_on(changeset).object == [
               "there is already a rule between these two — edit that one instead"
             ]
    end

    test "sides must differ and exist", %{scope: scope, jan: jan} do
      assert {:error, changeset} =
               Seating.create_rule(scope, %{
                 "subject" => "couple",
                 "object" => "couple",
                 "relation" => "seat_with"
               })

      assert "must be different from the first side" in errors_on(changeset).object

      assert {:error, changeset} =
               Seating.create_rule(scope, %{
                 "subject" => "person:#{jan.id}",
                 "object" => "circle:999999",
                 "relation" => "seat_with"
               })

      assert "no longer exists" in errors_on(changeset).object

      assert {:error, changeset} =
               Seating.create_rule(scope, %{
                 "subject" => "nonsense",
                 "object" => "couple",
                 "relation" => "seat_with"
               })

      assert "is not a person, circle or the couple" in errors_on(changeset).subject
    end

    test "the couple is named after the users (SEAT-03)", %{scope: scope, jan: jan} do
      {:ok, rule} =
        Seating.create_rule(scope, %{
          "subject" => "person:#{jan.id}",
          "object" => "couple",
          "relation" => "always_with"
        })

      # Users without a passkey are not assignable, so this test's couple is still unnamed.
      assert Seating.describe(rule) == "'the couple' always with 'Jan Peeters'"
    end

    test "update logs before → after; an unchanged save logs nothing", %{
      scope: scope,
      jan: jan,
      mia: mia
    } do
      {:ok, rule} =
        Seating.create_rule(scope, %{
          "subject" => "person:#{jan.id}",
          "object" => "person:#{mia.id}",
          "relation" => "seat_with"
        })

      {:ok, _} = Seating.update_rule(scope, rule, %{"relation" => "seat_with"})
      assert length(descriptions("seating_rule")) == 1

      {:ok, updated} = Seating.update_rule(scope, rule, %{"relation" => "keep_apart"})
      assert updated.relation == :keep_apart

      assert List.last(descriptions("seating_rule")) ==
               "Wannes changed the rule 'Jan Peeters' seat with 'Mia Peeters' to 'Jan Peeters' keep apart 'Mia Peeters'"
    end

    test "delete logs and the entry degrades to text (XC-10)", %{scope: scope, jan: jan, mia: mia} do
      {:ok, rule} =
        Seating.create_rule(scope, %{
          "subject" => "person:#{jan.id}",
          "object" => "person:#{mia.id}",
          "relation" => "seat_with"
        })

      assert {:link, _label, "/seating#rule-" <> _} = EntityRef.resolve("seating_rule", rule.id)
      {:ok, _} = Seating.delete_rule(scope, rule)

      assert List.last(descriptions("seating_rule")) ==
               "Wannes deleted the rule 'Jan Peeters' seat with 'Mia Peeters'"

      assert {:text, _} = EntityRef.resolve("seating_rule", rule.id)
    end
  end

  describe "deletion (SEAT-81, XC-40)" do
    test "deleting a circle deletes its rules and memberships, not its members",
         %{scope: scope, jan: jan, mia: mia} do
      circle = circle!(scope)
      {:ok, circle} = Seating.add_member(scope, circle, jan)

      {:ok, _} =
        Seating.create_rule(scope, %{
          "subject" => "circle:#{circle.id}",
          "object" => "person:#{mia.id}",
          "relation" => "keep_apart"
        })

      assert Seating.circle_deletion_effects(circle) == [
               %{label: "Also deletes 1 seating rule", count: 1}
             ]

      {:ok, _} = Seating.delete_circle(scope, circle)

      assert [%{role: :wedding_party}] = Seating.list_circles()
      assert Seating.list_rules() == []
      assert Repo.aggregate(CircleMembership, :count) == 0
      assert Guests.get_person!(jan.id)

      summary = Repo.one!(from e in Entry, where: is_nil(e.entity_type))
      assert summary.description == "Wannes deleted circle 'Uni friends'"

      assert [
               %{
                 description:
                   "Wannes deleted the rule 'Uni friends' keep apart 'Mia Peeters' (circle deleted)"
               }
             ] =
               Repo.all(from e in Entry, where: e.parent_id == ^summary.id)
    end

    test "deleting a person removes their memberships and rules, named in the confirmation",
         %{scope: scope, jan: jan, mia: mia} do
      circle = circle!(scope)
      {:ok, _} = Seating.add_member(scope, circle, jan)

      {:ok, _} =
        Seating.create_rule(scope, %{
          "subject" => "person:#{jan.id}",
          "object" => "person:#{mia.id}",
          "relation" => "never_with"
        })

      assert Guests.person_deletion_effects(jan) == [
               %{label: "Also removes from 1 circle", count: 1},
               %{label: "Also deletes 1 seating rule", count: 1}
             ]

      {:ok, _} = Guests.delete_person(scope, jan)

      assert Seating.list_rules() == []
      assert [%{members: []}] = Enum.reject(Seating.list_circles(), &Circle.wedding_party?/1)

      assert List.last(descriptions("person")) ==
               "Wannes deleted 'Jan Peeters' (1 circle membership, 1 seating rule removed)"
    end

    test "deleting a host deletes their +1's rules too", %{scope: scope, jan: jan, mia: mia} do
      {:ok, plus_one} =
        Guests.add_plus_one(scope, jan, %{"first_name" => "Tom", "plus_one_status" => "confirmed"})

      {:ok, _} =
        Seating.create_rule(scope, %{
          "subject" => "person:#{plus_one.id}",
          "object" => "person:#{mia.id}",
          "relation" => "seat_with"
        })

      {:ok, _} = Guests.delete_person(scope, jan)
      assert Seating.list_rules() == []
    end

    test "bulk deleting persons removes their rules", %{scope: scope, jan: jan, mia: mia} do
      {:ok, _} =
        Seating.create_rule(scope, %{
          "subject" => "person:#{jan.id}",
          "object" => "person:#{mia.id}",
          "relation" => "seat_with"
        })

      {:ok, _} = Guests.bulk_delete_persons(scope, [jan])
      assert Seating.list_rules() == []
    end
  end

  describe "tables (SEAT-40, D-42)" do
    setup %{scope: scope} do
      {:ok, dinner} =
        WeddingPlanner.Events.create_event(scope, %{"name" => "Dinner", "couple_attends" => false})

      %{dinner: dinner}
    end

    test "a table type with or without a limit, and a fixed table, are logged as such",
         %{scope: scope, dinner: dinner} do
      {:ok, round} =
        Seating.create_table(scope, dinner, %{
          "name" => "Round",
          "min_seats" => "8",
          "max_seats" => "10"
        })

      {:ok, square} =
        Seating.create_table(scope, dinner, %{
          "name" => "Square",
          "min_seats" => "4",
          "max_seats" => "4",
          "limit" => "3"
        })

      {:ok, head} =
        Seating.create_table(scope, dinner, %{
          "kind" => "fixed",
          "name" => "Head",
          "min_seats" => "2",
          "max_seats" => "6",
          "limit" => "9"
        })

      assert {round.kind, round.limit} == {:type, nil}
      assert {square.kind, square.limit} == {:type, 3}
      assert {head.kind, head.limit} == {:fixed, nil}
      assert Enum.map(Seating.list_tables(dinner.id), & &1.name) == ["Round", "Square", "Head"]

      assert descriptions("seating_table") == [
               "Wannes added table type 'Round' (8–10 seats) to 'Dinner'",
               "Wannes added table type 'Square' (4 seats, at most 3) to 'Dinner'",
               "Wannes added fixed table 'Head' (2–6 seats) to 'Dinner'"
             ]
    end

    test "seats must be 1 ≤ min ≤ max; a limit at least 1; names unique per event",
         %{scope: scope, dinner: dinner} do
      assert {:error, changeset} =
               Seating.create_table(scope, dinner, %{
                 "name" => "Head",
                 "min_seats" => "6",
                 "max_seats" => "4"
               })

      assert "must be at least the minimum" in errors_on(changeset).max_seats

      assert {:error, changeset} =
               Seating.create_table(scope, dinner, %{
                 "name" => "Round",
                 "min_seats" => "6",
                 "max_seats" => "8",
                 "limit" => "0"
               })

      assert "must be greater than or equal to 1" in errors_on(changeset).limit

      {:ok, _} =
        Seating.create_table(scope, dinner, %{
          "name" => "Head",
          "min_seats" => "4",
          "max_seats" => "6"
        })

      assert {:error, changeset} =
               Seating.create_table(scope, dinner, %{
                 "name" => "Head",
                 "min_seats" => "4",
                 "max_seats" => "6"
               })

      assert "another table of this event already has this name" in errors_on(changeset).name
    end

    test "update and delete are logged and broadcast", %{scope: scope, dinner: dinner} do
      Realtime.subscribe(:seating_table)

      {:ok, table} =
        Seating.create_table(scope, dinner, %{
          "name" => "Round",
          "min_seats" => "8",
          "max_seats" => "10"
        })

      assert_receive {Realtime, :seating_table, {:created, _}}

      {:ok, table} = Seating.update_table(scope, table, %{"limit" => "4"})
      assert_receive {Realtime, :seating_table, {:updated, %{limit: 4}}}

      {:ok, _} = Seating.delete_table(scope, table)
      assert_receive {Realtime, :seating_table, {:deleted, _}}

      assert tl(descriptions("seating_table")) == [
               "Wannes changed table type 'Round' (8–10 seats) to table type 'Round' (8–10 seats, at most 4)",
               "Wannes deleted table type 'Round' (8–10 seats, at most 4)"
             ]
    end

    test "deleting the event deletes its tables, named in EVT-05's warning (SEAT-81)",
         %{scope: scope, dinner: dinner} do
      {:ok, _} =
        Seating.create_table(scope, dinner, %{
          "kind" => "fixed",
          "name" => "Head",
          "min_seats" => "4",
          "max_seats" => "6"
        })

      assert %{label: "1 seating table", count: 1} in WeddingPlanner.Events.affected_references(
               dinner
             )

      {:ok, _} = WeddingPlanner.Events.delete_event(scope, dinner)
      assert Seating.list_tables(dinner.id) == []

      assert List.last(descriptions("seating_table")) ==
               "Wannes deleted fixed table 'Head' (4–6 seats) (event 'Dinner' deleted)"
    end
  end

  describe "the wedding party (SEAT-24)" do
    test "exists from the start, keeps together, and cannot be deleted", %{scope: scope} do
      party = Enum.find(Seating.list_circles(), &Circle.wedding_party?/1)

      assert party.name == "Wedding party"
      assert party.cohesion == :keep_together
      assert Seating.delete_circle(scope, party) == {:error, :built_in}

      {:ok, renamed} = Seating.update_circle(scope, party, %{"name" => "Head table crew"})
      assert Circle.wedding_party?(renamed)
    end
  end

  describe "pins (SEAT-42, D-44)" do
    setup %{scope: scope} do
      {:ok, dinner} =
        WeddingPlanner.Events.create_event(scope, %{"name" => "Dinner", "couple_attends" => true})

      {:ok, head} =
        Seating.create_table(scope, dinner, %{
          "kind" => "fixed",
          "name" => "Head",
          "min_seats" => "2",
          "max_seats" => "8"
        })

      {:ok, round} =
        Seating.create_table(scope, dinner, %{
          "name" => "Round",
          "min_seats" => "8",
          "max_seats" => "10"
        })

      %{dinner: dinner, head: head, round: round}
    end

    test "a person, the couple or a circle can be pinned to a fixed table, once",
         %{scope: scope, dinner: dinner, head: head, jan: jan} do
      party = Enum.find(Seating.list_circles(), &Circle.wedding_party?/1)

      {:ok, pin} = Seating.pin(scope, head, "circle:#{party.id}")
      {:ok, ^pin} = Seating.pin(scope, head, "circle:#{party.id}")
      {:ok, _} = Seating.pin(scope, head, "couple")
      {:ok, _} = Seating.pin(scope, head, "person:#{jan.id}")

      assert dinner.id |> Seating.list_pins() |> Enum.map(& &1.target_key) ==
               ["circle:#{party.id}", "couple", "person:#{jan.id}"]

      assert descriptions("seating_table") |> Enum.take(-3) == [
               "Wannes pinned 'Wedding party' to 'Head'",
               "Wannes pinned 'the couple' to 'Head'",
               "Wannes pinned 'Jan Peeters' to 'Head'"
             ]

      {:ok, _} = Seating.unpin(scope, pin)

      assert List.last(descriptions("seating_table")) ==
               "Wannes unpinned 'Wedding party' from 'Head'"
    end

    test "only to a fixed table, and only something that exists", %{
      scope: scope,
      round: round,
      head: head
    } do
      assert Seating.pin(scope, round, "couple") == {:error, :not_fixed}
      assert Seating.pin(scope, head, "person:999999") == {:error, :unknown_side}
      assert Seating.pin(scope, head, "nonsense") == {:error, :unknown_side}
    end

    test "deleting the table, the person or the circle removes the pin (SEAT-81)",
         %{scope: scope, dinner: dinner, head: head, jan: jan, mia: mia} do
      {:ok, circle} =
        Seating.create_circle(scope, %{"name" => "Work", "cohesion" => "like_together"})

      {:ok, _} = Seating.pin(scope, head, "circle:#{circle.id}")
      {:ok, _} = Seating.pin(scope, head, "person:#{jan.id}")
      {:ok, _} = Seating.pin(scope, head, "person:#{mia.id}")

      assert %{label: "Also removes 1 pin", count: 1} in Seating.circle_deletion_effects(circle)
      {:ok, _} = Seating.delete_circle(scope, circle)
      assert length(Seating.list_pins(dinner.id)) == 2

      assert %{label: "Also removes 1 seating pin", count: 1} in Guests.person_deletion_effects(
               jan
             )

      {:ok, _} = Guests.delete_person(scope, jan)
      assert [%{person_id: mia_id}] = Seating.list_pins(dinner.id)
      assert mia_id == mia.id

      assert Seating.table_deletion_effects(head) == [%{label: "Also removes 1 pin", count: 1}]
      {:ok, _} = Seating.delete_table(scope, head)
      assert Seating.list_pins(dinner.id) == []
      assert List.last(descriptions("seating_table")) =~ "(1 pin removed)"
    end

    test "deleting the event removes its tables' pins", %{
      scope: scope,
      dinner: dinner,
      head: head
    } do
      {:ok, _} = Seating.pin(scope, head, "couple")
      {:ok, _} = WeddingPlanner.Events.delete_event(scope, dinner)
      assert Repo.aggregate(WeddingPlanner.Seating.Pin, :count) == 0
    end
  end

  describe "fine anywhere (SEAT-35)" do
    test "is off by default, set through update_person and logged", %{scope: scope, jan: jan} do
      refute jan.fine_anywhere

      {:ok, jan} = Guests.update_person(scope, jan, %{"fine_anywhere" => "true"})
      assert jan.fine_anywhere

      assert List.last(descriptions("person")) ==
               "Wannes changed the fine anywhere of 'Jan Peeters': off → on"
    end

    test "a +1 has its own", %{scope: scope, jan: jan} do
      {:ok, plus_one} = Guests.add_plus_one(scope, jan, %{"plus_one_status" => "confirmed"})

      assert {:ok, %{fine_anywhere: true}} =
               Guests.update_person(scope, plus_one, %{"fine_anywhere" => "true"})
    end
  end
end
