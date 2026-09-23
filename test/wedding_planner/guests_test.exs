defmodule WeddingPlanner.GuestsTest do
  @moduledoc """
  `docs/modules/guests-and-events.md` `PER-01` through `PER-07`, `docs/04-cross-cutting.md`
  `XC-01`, `XC-02`, `XC-10` through `XC-13` — the guest list's data layer (slice G1).
  """
  use WeddingPlanner.DataCase, async: true

  alias WeddingPlanner.Accounts.Scope
  alias WeddingPlanner.Accounts.User
  alias WeddingPlanner.Guests
  alias WeddingPlanner.Guests.Group
  alias WeddingPlanner.Guests.Person
  alias WeddingPlanner.Log.Entry
  alias WeddingPlanner.Log.EntityRef
  alias WeddingPlanner.Log.Query, as: LogQuery
  alias WeddingPlanner.Realtime
  alias WeddingPlanner.Valuation.Snapshot

  setup do
    user = insert_user!("Wannes")
    %{user: user, scope: Scope.for_user(user)}
  end

  # -- list_persons/1 (PER-05) ---------------------------------------------------------

  describe "list_persons/1 — default sort (DR-26 Q8)" do
    test "last name wins, falling back to first name, case-insensitively, particles kept", %{
      scope: scope
    } do
      {:ok, anna} =
        Guests.create_person(scope, %{"first_name" => "anna", "last_name" => "Aerts"})

      {:ok, bert} = Guests.create_person(scope, %{"first_name" => "Bert", "last_name" => "Aerts"})
      {:ok, marc} = Guests.create_person(scope, %{"first_name" => "Marc", "last_name" => "Claes"})
      {:ok, piet} = Guests.create_person(scope, %{"first_name" => "Piet", "last_name" => "Damme"})

      {:ok, eva} =
        Guests.create_person(scope, %{"first_name" => "Eva", "last_name" => "de Smet"})

      {:ok, sven} = Guests.create_person(scope, %{"first_name" => "Sven", "last_name" => "Nys"})
      {:ok, oma} = Guests.create_person(scope, %{"first_name" => "Oma"})

      {:ok, kristof} =
        Guests.create_person(scope, %{"first_name" => "Kristof", "last_name" => "Peeters"})

      {:ok, jan} =
        Guests.create_person(scope, %{"first_name" => "Jan", "last_name" => "Van Damme"})

      ids = Guests.list_persons() |> Enum.map(& &1.id)

      assert ids == [
               anna.id,
               bert.id,
               marc.id,
               piet.id,
               eva.id,
               sven.id,
               oma.id,
               kristof.id,
               jan.id
             ]

      # "Oma" (first name only) sits between "Nys" and "Peeters".
      oma_index = Enum.find_index(ids, &(&1 == oma.id))
      assert Enum.at(ids, oma_index - 1) == sven.id
      assert Enum.at(ids, oma_index + 1) == kristof.id

      # "de Smet" sits between "Claes" and "Peeters".
      assert Enum.find_index(ids, &(&1 == eva.id)) >
               Enum.find_index(ids, &(&1 == marc.id))

      assert Enum.find_index(ids, &(&1 == eva.id)) <
               Enum.find_index(ids, &(&1 == kristof.id))

      # A lower-case "anna Aerts" sorts before "Bert Aerts".
      assert Enum.find_index(ids, &(&1 == anna.id)) <
               Enum.find_index(ids, &(&1 == bert.id))

      # "Van Damme" sorts under V (last), not merged with plain "Damme" (D).
      assert List.last(ids) == jan.id
      assert Enum.find_index(ids, &(&1 == piet.id)) < Enum.find_index(ids, &(&1 == jan.id))
    end
  end

  describe "list_persons/1 — filters" do
    setup %{scope: scope} do
      {:ok, family} = Guests.create_group(scope, %{"name" => "Family Peeters"})

      {:ok, anna} =
        Guests.create_person(scope, %{
          "first_name" => "Anna",
          "last_name" => "Peeters",
          "age_category" => "adult",
          "want_tier" => "yes",
          "certainty" => "certain",
          "notes" => "Vegetarian",
          "group_id" => family.id
        })

      {:ok, bo} =
        Guests.create_person(scope, %{
          "first_name" => "Bo",
          "age_category" => "child",
          "want_tier" => "maybe",
          "certainty" => "uncertain"
        })

      {:ok, chris} =
        Guests.create_person(scope, %{
          "first_name" => "Chris",
          "last_name" => "Vermeulen",
          "age_category" => "adult",
          "want_tier" => "obligated",
          "certainty" => "likely",
          "notes" => "Allergic to nuts"
        })

      %{family: family, anna: anna, bo: bo, chris: chris}
    end

    test "text filter matches first name, last name and notes", %{anna: anna, chris: chris} do
      assert Guests.list_persons(%{filters: %{text: "peeters"}}) |> Enum.map(& &1.id) == [
               anna.id
             ]

      assert Guests.list_persons(%{filters: %{text: "nuts"}}) |> Enum.map(& &1.id) == [chris.id]
    end

    test "group_id filter narrows to one group's members", %{family: family, anna: anna} do
      assert Guests.list_persons(%{filters: %{group_id: family.id}}) |> Enum.map(& &1.id) == [
               anna.id
             ]
    end

    test ":ungrouped filters to persons with no group", %{bo: bo, chris: chris} do
      ids = Guests.list_persons(%{filters: %{group_id: :ungrouped}}) |> Enum.map(& &1.id)
      assert Enum.sort(ids) == Enum.sort([bo.id, chris.id])
    end

    test "age_category filter", %{bo: bo} do
      assert Guests.list_persons(%{filters: %{age_category: :child}}) |> Enum.map(& &1.id) == [
               bo.id
             ]
    end

    test "want_tier filter", %{chris: chris} do
      assert Guests.list_persons(%{filters: %{want_tier: :obligated}}) |> Enum.map(& &1.id) == [
               chris.id
             ]
    end

    test "certainty filter", %{anna: anna} do
      assert Guests.list_persons(%{filters: %{certainty: :certain}}) |> Enum.map(& &1.id) == [
               anna.id
             ]
    end

    test "filters combine (AND)", %{anna: anna} do
      assert Guests.list_persons(%{filters: %{age_category: :adult, want_tier: :yes}})
             |> Enum.map(& &1.id) == [anna.id]
    end
  end

  describe "change_person/2 — group existence (PER-03)" do
    test "create_person/2 rejects a group_id that does not exist", %{scope: scope} do
      assert {:error, changeset} =
               Guests.create_person(scope, %{"first_name" => "Bo", "group_id" => 999_999})

      assert "does not exist" in errors_on(changeset).group_id
      assert Repo.aggregate(Person, :count) == 0
    end

    test "create_person/2 accepts a real group_id", %{scope: scope} do
      {:ok, group} = Guests.create_group(scope, %{"name" => "Family Peeters"})

      assert {:ok, person} =
               Guests.create_person(scope, %{"first_name" => "Bo", "group_id" => group.id})

      assert person.group_id == group.id
    end
  end

  # -- update_person/3 (XC-10, XC-01) --------------------------------------------------

  describe "update_person/3" do
    setup %{scope: scope} do
      {:ok, group} = Guests.create_group(scope, %{"name" => "Family Peeters"})

      {:ok, person} =
        Guests.create_person(scope, %{"first_name" => "Anna", "last_name" => "Peeters"})

      %{group: group, person: person}
    end

    test "writes one entry per changed field, old -> new labels", %{scope: scope, person: person} do
      {:ok, _updated} = Guests.update_person(scope, person, %{"want_tier" => "maybe"})

      entries = person_update_entries(person)
      assert [entry] = entries

      assert entry.description ==
               "Wannes changed the want tier of 'Anna Peeters': Yes → Maybe"
    end

    test "the group field logs the group's name, not its id", %{
      scope: scope,
      person: person,
      group: group
    } do
      {:ok, _updated} = Guests.update_person(scope, person, %{"group_id" => group.id})

      entries = person_update_entries(person)
      assert [entry] = entries

      assert entry.description ==
               "Wannes changed the group of 'Anna Peeters': none → Family Peeters"
    end

    test "logs multiple entries when multiple fields change at once", %{
      scope: scope,
      person: person
    } do
      {:ok, _updated} =
        Guests.update_person(scope, person, %{"want_tier" => "no", "certainty" => "uncertain"})

      descriptions =
        person
        |> person_update_entries()
        |> Enum.map(& &1.description)
        |> Enum.sort()

      assert descriptions == [
               "Wannes changed the certainty of 'Anna Peeters': Likely → Uncertain",
               "Wannes changed the want tier of 'Anna Peeters': Yes → No"
             ]
    end

    test "writes nothing when nothing changed", %{scope: scope, person: person} do
      {:ok, _updated} = Guests.update_person(scope, person, %{"first_name" => "Anna"})

      assert person_update_entries(person) == []
    end

    test "broadcasts {:updated, person} (XC-01)", %{scope: scope, person: person} do
      Realtime.subscribe(:person)
      assert {:ok, updated} = Guests.update_person(scope, person, %{"want_tier" => "maybe"})

      assert_received {Realtime, :person, {:updated, ^updated}}
    end
  end

  # -- bulk_create_persons/3 (PER-04, XC-12) -------------------------------------------

  describe "bulk_create_persons/3" do
    test "one summary plus one child per person", %{scope: scope} do
      name_maps = [
        %{first_name: "Griet", last_name: "Van Acker"},
        %{first_name: "Ines", last_name: "Van Acker"},
        %{first_name: "Bo", last_name: nil}
      ]

      assert {:ok, persons} = Guests.bulk_create_persons(scope, name_maps)
      assert length(persons) == 3

      entries = Repo.all(Entry)
      {[summary], children} = Enum.split_with(entries, &is_nil(&1.entity_type))

      assert summary.description == "Wannes added 3 people"
      assert length(children) == 3
      assert Enum.all?(children, &(&1.parent_id == summary.id))

      assert LogQuery.children(summary.id) |> Enum.map(& &1.description) |> Enum.sort() ==
               [
                 "Wannes added 'Bo'",
                 "Wannes added 'Griet Van Acker'",
                 "Wannes added 'Ines Van Acker'"
               ]
    end

    test "shared attrs apply to every created person", %{scope: scope} do
      {:ok, group} = Guests.create_group(scope, %{"name" => "Family Peeters"})

      {:ok, [a, b]} =
        Guests.bulk_create_persons(
          scope,
          [%{first_name: "A"}, %{first_name: "B"}],
          %{group_id: group.id, want_tier: :maybe}
        )

      assert a.group_id == group.id
      assert a.want_tier == :maybe
      assert b.group_id == group.id
    end

    test "all-or-nothing: an invalid entry rolls the whole batch back", %{scope: scope} do
      name_maps = [
        %{first_name: "Valid"},
        %{first_name: nil, last_name: nil},
        %{first_name: "AlsoValid"}
      ]

      assert {:error, _changeset} = Guests.bulk_create_persons(scope, name_maps)
      assert Repo.aggregate(Person, :count) == 0
      assert Repo.all(Entry) == []
    end

    test "broadcasts {:created, person} for each person", %{scope: scope} do
      Realtime.subscribe(:person)

      {:ok, [person]} = Guests.bulk_create_persons(scope, [%{first_name: "Bo"}])

      assert_received {Realtime, :person, {:created, ^person}}
    end
  end

  # -- bulk_update_persons/4 (PER-04, XC-12) -------------------------------------------

  describe "bulk_update_persons/4" do
    test "one summary, children only for persons whose value actually changed", %{scope: scope} do
      {:ok, a} =
        Guests.create_person(scope, %{"first_name" => "A", "want_tier" => "yes"})

      {:ok, b} =
        Guests.create_person(scope, %{"first_name" => "B", "want_tier" => "yes"})

      {:ok, c} =
        Guests.create_person(scope, %{"first_name" => "C", "want_tier" => "maybe"})

      {:ok, updated} = Guests.bulk_update_persons(scope, [a, b, c], :want_tier, :maybe)
      assert Enum.sort(Enum.map(updated, & &1.id)) == Enum.sort([a.id, b.id])

      summary = Repo.all(Entry) |> Enum.find(&is_nil(&1.entity_type))
      children = LogQuery.children(summary.id)

      assert summary.description == "Wannes set 2 people to want tier Maybe"
      assert length(children) == 2
      assert Enum.sort(Enum.map(children, & &1.entity_id)) == Enum.sort([a.id, b.id])
    end

    test "names the group when the selection is exactly all of its members (XC-12)", %{
      scope: scope
    } do
      {:ok, group} = Guests.create_group(scope, %{"name" => "Family Peeters"})

      members =
        for name <- ["A", "B", "C", "D"] do
          {:ok, person} =
            Guests.create_person(scope, %{
              "first_name" => name,
              "group_id" => group.id,
              "want_tier" => "yes"
            })

          person
        end

      {:ok, _updated} = Guests.bulk_update_persons(scope, members, :want_tier, :maybe)

      summary = Repo.all(Entry) |> Enum.find(&is_nil(&1.entity_type))

      assert summary.description ==
               "Wannes set 4 people in 'Family Peeters' to want tier Maybe"
    end

    test "does not name the group when the selection is a strict subset of its members", %{
      scope: scope
    } do
      {:ok, group} = Guests.create_group(scope, %{"name" => "Family Peeters"})

      {:ok, a} =
        Guests.create_person(scope, %{
          "first_name" => "A",
          "group_id" => group.id,
          "want_tier" => "yes"
        })

      {:ok, _b} =
        Guests.create_person(scope, %{
          "first_name" => "B",
          "group_id" => group.id,
          "want_tier" => "yes"
        })

      {:ok, _updated} = Guests.bulk_update_persons(scope, [a], :want_tier, :maybe)

      summary = Repo.all(Entry) |> Enum.find(&is_nil(&1.entity_type))
      assert summary.description == "Wannes set 1 person to want tier Maybe"
    end

    test "writes no group-level state (PER-04)", %{scope: scope} do
      {:ok, a} = Guests.create_person(scope, %{"first_name" => "A"})
      {:ok, _updated} = Guests.bulk_update_persons(scope, [a], :certainty, :certain)

      assert Repo.aggregate(Group, :count) == 0
    end
  end

  # -- bulk_delete_persons/2 (PER-07, XC-12) -------------------------------------------

  describe "bulk_delete_persons/2" do
    test "one summary naming the count and names, a child per person", %{scope: scope} do
      {:ok, griet} =
        Guests.create_person(scope, %{"first_name" => "Griet", "last_name" => "Van Acker"})

      {:ok, ines} =
        Guests.create_person(scope, %{"first_name" => "Ines", "last_name" => "Van Acker"})

      {:ok, bo} = Guests.create_person(scope, %{"first_name" => "Bo"})

      assert {:ok, _deleted} = Guests.bulk_delete_persons(scope, [griet, ines, bo])

      assert Repo.aggregate(Person, :count) == 0

      entries = Repo.all(Entry) |> Enum.reject(&(&1.description =~ "added"))
      {[summary], children} = Enum.split_with(entries, &is_nil(&1.entity_type))

      assert summary.description ==
               "Wannes deleted 3 people: Griet Van Acker, Ines Van Acker, Bo"

      assert length(children) == 3
      assert Enum.all?(children, &(&1.parent_id == summary.id))
    end
  end

  # -- delete_group/2 (PER-07, XC-10, XC-11) -------------------------------------------

  describe "delete_group/2" do
    setup %{scope: scope} do
      {:ok, group} = Guests.create_group(scope, %{"name" => "Family Peeters"})

      {:ok, anna} =
        Guests.create_person(scope, %{
          "first_name" => "Anna",
          "last_name" => "Peeters",
          "notes" => "Keep her notes",
          "group_id" => group.id
        })

      {:ok, bo} =
        Guests.create_person(scope, %{"first_name" => "Bo", "group_id" => group.id})

      %{group: group, anna: anna, bo: bo}
    end

    test "members remain, with group_id nil and every other field intact", %{
      scope: scope,
      group: group,
      anna: anna
    } do
      assert {:ok, _deleted} = Guests.delete_group(scope, group)

      reloaded = Guests.get_person!(anna.id)
      assert is_nil(reloaded.group_id)
      assert reloaded.first_name == "Anna"
      assert reloaded.last_name == "Peeters"
      assert reloaded.notes == "Keep her notes"
    end

    test "each member's own history has the 'removed from ... (group deleted)' entry", %{
      scope: scope,
      group: group,
      anna: anna,
      bo: bo
    } do
      {:ok, _deleted} = Guests.delete_group(scope, group)

      anna_history = LogQuery.for_entity(:person, anna.id) |> Enum.map(& &1.description)

      assert "Wannes removed 'Anna Peeters' from 'Family Peeters' (group deleted)" in anna_history

      bo_history = LogQuery.for_entity(:person, bo.id) |> Enum.map(& &1.description)
      assert "Wannes removed 'Bo' from 'Family Peeters' (group deleted)" in bo_history
    end

    test "the summary names the member count", %{scope: scope, group: group} do
      {:ok, _deleted} = Guests.delete_group(scope, group)

      summary =
        Repo.all(Entry)
        |> Enum.find(&(&1.description =~ "deleted group"))

      assert summary.description == "Wannes deleted group 'Family Peeters' (2 people ungrouped)"
      assert is_nil(summary.entity_type)
    end

    test "group_deletion_effects/1 reports the member count beforehand", %{group: group} do
      assert Guests.group_deletion_effects(group) == [
               %{label: "2 people become ungrouped, not deleted", count: 2}
             ]
    end

    test "a group with no members reports no effects", %{scope: scope} do
      {:ok, empty_group} = Guests.create_group(scope, %{"name" => "Empty"})
      assert Guests.group_deletion_effects(empty_group) == []
    end

    test "broadcasts {:updated, person} for each member and {:deleted, id} for the group", %{
      scope: scope,
      group: group,
      anna: anna,
      bo: bo
    } do
      Realtime.subscribe(:person)
      Realtime.subscribe(:group)

      {:ok, _deleted} = Guests.delete_group(scope, group)

      assert_received {Realtime, :person, {:updated, updated_anna}}
      assert updated_anna.id == anna.id
      assert_received {Realtime, :person, {:updated, updated_bo}}
      assert updated_bo.id == bo.id

      group_id = group.id
      assert_received {Realtime, :group, {:deleted, ^group_id}}
    end
  end

  # -- log resolvers (DR-26 Q9) ---------------------------------------------------------

  describe "WeddingPlanner.Log.EntityRef 'person'/'group' resolvers" do
    test "resolves an existing person to a navigable link", %{scope: scope} do
      {:ok, person} = Guests.create_person(scope, %{"first_name" => "Anna", "last_name" => "P"})

      assert {:link, "Anna P", "/people/" <> _} = EntityRef.resolve("person", person.id)
    end

    test "a deleted person degrades to text", %{scope: scope} do
      {:ok, person} = Guests.create_person(scope, %{"first_name" => "Anna"})
      {:ok, _} = Guests.delete_person(scope, person)

      assert {:text, _label} = EntityRef.resolve("person", person.id)
    end

    test "resolves an existing group to the grouped view, anchored", %{scope: scope} do
      {:ok, group} = Guests.create_group(scope, %{"name" => "Family Peeters"})

      assert {:link, "Family Peeters", "/people?view=grouped#group-" <> _} =
               EntityRef.resolve("group", group.id)
    end

    test "a deleted group degrades to text", %{scope: scope} do
      {:ok, group} = Guests.create_group(scope, %{"name" => "Family Peeters"})
      {:ok, _} = Guests.delete_group(scope, group)

      assert {:text, _label} = EntityRef.resolve("group", group.id)
    end
  end

  # -- Valuation.Snapshot spine hookup --------------------------------------------------

  describe "WeddingPlanner.Valuation.Snapshot.load/1" do
    test "returns the persons and groups", %{scope: scope} do
      {:ok, group} = Guests.create_group(scope, %{"name" => "Family Peeters"})

      {:ok, person} =
        Guests.create_person(scope, %{"first_name" => "Anna", "group_id" => group.id})

      snapshot = Snapshot.load(Repo)

      assert Enum.map(snapshot.persons, & &1.id) == [person.id]
      assert Enum.map(snapshot.groups, & &1.id) == [group.id]
    end
  end

  defp person_update_entries(person) do
    LogQuery.for_entity(:person, person.id) |> Enum.reject(&(&1.description =~ "added"))
  end

  defp insert_user!(display_name) do
    %User{} |> User.changeset(%{display_name: display_name}) |> Repo.insert!()
  end
end
