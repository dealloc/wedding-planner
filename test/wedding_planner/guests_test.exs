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
  alias WeddingPlanner.Guests.PlusOne
  alias WeddingPlanner.Log.Entry
  alias WeddingPlanner.Log.EntityRef
  alias WeddingPlanner.Log.Query, as: LogQuery
  alias WeddingPlanner.Presets
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

  # -- +1s (PER-10 through PER-16, G2, DR-32, DR-34) -----------------------------------

  describe "add_plus_one/3 (PER-10, PER-12)" do
    setup %{scope: scope} do
      {:ok, host} =
        Guests.create_person(scope, %{
          "first_name" => "Anna",
          "last_name" => "Peeters",
          "want_tier" => "yes",
          "certainty" => "certain"
        })

      %{host: host}
    end

    test "possible, unnamed", %{scope: scope, host: host} do
      assert {:ok, plus_one} = Guests.add_plus_one(scope, host, %{})
      assert plus_one.host_id == host.id
      assert plus_one.plus_one_status == :possible
      refute Person.name_known?(plus_one)
      assert Person.display_name(plus_one) == "+1 of Anna Peeters"
    end

    test "possible, named", %{scope: scope, host: host} do
      assert {:ok, plus_one} =
               Guests.add_plus_one(scope, host, %{"first_name" => "Tom", "last_name" => "Wils"})

      assert plus_one.plus_one_status == :possible
      assert Person.display_name(plus_one) == "Tom Wils"
    end

    test "confirmed, unnamed", %{scope: scope, host: host} do
      assert {:ok, plus_one} =
               Guests.add_plus_one(scope, host, %{"plus_one_status" => "confirmed"})

      assert plus_one.plus_one_status == :confirmed
      refute Person.name_known?(plus_one)
    end

    test "confirmed, named", %{scope: scope, host: host} do
      assert {:ok, plus_one} =
               Guests.add_plus_one(scope, host, %{
                 "plus_one_status" => "confirmed",
                 "first_name" => "Tom",
                 "last_name" => "Wils"
               })

      assert plus_one.plus_one_status == :confirmed
      assert Person.display_name(plus_one) == "Tom Wils"
    end

    test "want_tier and certainty are written from the host at creation", %{
      scope: scope,
      host: host
    } do
      {:ok, plus_one} = Guests.add_plus_one(scope, host, %{})
      assert plus_one.want_tier == :yes
      assert plus_one.certainty == :certain
    end

    test "a host may have several +1s", %{scope: scope, host: host} do
      {:ok, first} = Guests.add_plus_one(scope, host, %{"first_name" => "Tom"})
      {:ok, second} = Guests.add_plus_one(scope, host, %{"first_name" => "Jan"})

      assert first.host_id == host.id
      assert second.host_id == host.id
      assert first.id != second.id
    end

    test "logs 'added a +1 for' against the +1, wording matches possible/confirmed x named/unnamed",
         %{scope: scope, host: host} do
      {:ok, unnamed_possible} = Guests.add_plus_one(scope, host, %{})

      {:ok, named_confirmed} =
        Guests.add_plus_one(scope, host, %{
          "plus_one_status" => "confirmed",
          "first_name" => "Tom",
          "last_name" => "Wils"
        })

      unnamed_entry = LogQuery.for_entity(:person, unnamed_possible.id) |> List.first()

      assert unnamed_entry.description ==
               "Wannes added a +1 for 'Anna Peeters' (possible, unnamed)"

      named_entry = LogQuery.for_entity(:person, named_confirmed.id) |> List.first()

      assert named_entry.description ==
               "Wannes added a +1 for 'Anna Peeters' (confirmed, 'Tom Wils')"
    end

    test "broadcasts {:created, plus_one} (XC-01)", %{scope: scope, host: host} do
      Realtime.subscribe(:person)
      {:ok, plus_one} = Guests.add_plus_one(scope, host, %{})

      assert_received {Realtime, :person, {:created, ^plus_one}}
    end

    test "refuses a host that does not exist (PER-10)", %{scope: scope, host: host} do
      deleted_host = Map.put(host, :id, host.id + 999_999)
      assert {:error, changeset} = Guests.add_plus_one(scope, deleted_host, %{})
      assert "does not exist" in errors_on(changeset).host_id
      assert Repo.aggregate(Person, :count) == 1
    end

    test "refuses a host that is itself a +1 — no chains (PER-10)", %{scope: scope, host: host} do
      {:ok, plus_one} = Guests.add_plus_one(scope, host, %{"first_name" => "Tom"})

      assert {:error, changeset} = Guests.add_plus_one(scope, plus_one, %{})
      assert "must not itself be a +1" in errors_on(changeset).host_id
      assert Repo.aggregate(Person, :count) == 2
    end
  end

  describe "PER-10 — database-level guarantees" do
    setup %{scope: scope} do
      {:ok, host} = Guests.create_person(scope, %{"first_name" => "Anna"})
      %{host: host}
    end

    test "the CHECK constraint rejects host_id = id via a raw update", %{host: host} do
      assert_raise Exqlite.Error, ~r/CHECK constraint failed/, fn ->
        Repo.update_all(
          from(p in Person, where: p.id == ^host.id),
          set: [host_id: host.id, plus_one_status: "possible"]
        )
      end
    end

    test "the CHECK constraint rejects plus_one_status set without host_id", %{host: host} do
      assert_raise Exqlite.Error, ~r/CHECK constraint failed/, fn ->
        Repo.update_all(
          from(p in Person, where: p.id == ^host.id),
          set: [plus_one_status: "possible"]
        )
      end
    end
  end

  describe "confirm_plus_one/2 (PER-12)" do
    setup %{scope: scope} do
      {:ok, host} =
        Guests.create_person(scope, %{"first_name" => "Anna", "last_name" => "Peeters"})

      {:ok, plus_one} = Guests.add_plus_one(scope, host, %{})
      %{host: host, plus_one: plus_one}
    end

    test "possible -> confirmed is one call", %{scope: scope, plus_one: plus_one} do
      assert {:ok, confirmed} = Guests.confirm_plus_one(scope, plus_one)
      assert confirmed.plus_one_status == :confirmed
    end

    test "logs once, naming the +1's display name", %{scope: scope, plus_one: plus_one} do
      {:ok, _confirmed} = Guests.confirm_plus_one(scope, plus_one)

      entries =
        LogQuery.for_entity(:person, plus_one.id)
        |> Enum.reject(&(&1.description =~ "added"))

      assert [entry] = entries
      assert entry.description == "Wannes confirmed '+1 of Anna Peeters' (possible → confirmed)"
    end

    test "already confirmed is a no-op: no log entry, no broadcast", %{
      scope: scope,
      plus_one: plus_one
    } do
      {:ok, confirmed} = Guests.confirm_plus_one(scope, plus_one)

      Realtime.subscribe(:person)
      assert {:ok, ^confirmed} = Guests.confirm_plus_one(scope, confirmed)
      refute_received {Realtime, :person, {:updated, _}}

      entries =
        LogQuery.for_entity(:person, plus_one.id)
        |> Enum.reject(&(&1.description =~ "added"))

      assert length(entries) == 1
    end
  end

  describe "name_plus_one/3 (PER-11, PER-12)" do
    setup %{scope: scope} do
      {:ok, host} =
        Guests.create_person(scope, %{"first_name" => "Anna", "last_name" => "Peeters"})

      {:ok, plus_one} = Guests.add_plus_one(scope, host, %{})
      %{host: host, plus_one: plus_one}
    end

    test "naming is one call", %{scope: scope, plus_one: plus_one} do
      assert {:ok, named} =
               Guests.name_plus_one(scope, plus_one, %{
                 "first_name" => "Tom",
                 "last_name" => "Wils"
               })

      assert Person.display_name(named) == "Tom Wils"
    end

    test "logs once, old display name resolved from the host", %{
      scope: scope,
      plus_one: plus_one
    } do
      {:ok, _named} =
        Guests.name_plus_one(scope, plus_one, %{"first_name" => "Tom", "last_name" => "Wils"})

      entries =
        LogQuery.for_entity(:person, plus_one.id)
        |> Enum.reject(&(&1.description =~ "added"))

      assert [entry] = entries
      assert entry.description == "Wannes named '+1 of Anna Peeters': Tom Wils"
    end

    test "requires at least one name part", %{scope: scope, plus_one: plus_one} do
      assert {:error, changeset} = Guests.name_plus_one(scope, plus_one, %{})
      errors = errors_on(changeset)
      assert "must provide a first or last name" in errors.first_name
    end

    test "+1 status and name are independent: naming does not touch status", %{
      scope: scope,
      plus_one: plus_one
    } do
      {:ok, named} =
        Guests.name_plus_one(scope, plus_one, %{"first_name" => "Tom", "last_name" => "Wils"})

      assert named.plus_one_status == :possible
    end
  end

  describe "update_person/3 on a +1 (PER-15)" do
    setup %{scope: scope} do
      {:ok, host} =
        Guests.create_person(scope, %{
          "first_name" => "Anna",
          "last_name" => "Peeters",
          "want_tier" => "yes",
          "certainty" => "certain"
        })

      {:ok, plus_one} = Guests.add_plus_one(scope, host, %{"first_name" => "Tom"})
      %{host: host, plus_one: plus_one}
    end

    test "own age is editable", %{scope: scope, plus_one: plus_one} do
      assert {:ok, updated} = Guests.update_person(scope, plus_one, %{"age_category" => "child"})
      assert updated.age_category == :child
    end

    test "plus_one_status is editable via update_person/3, logged as '+1 status'", %{
      scope: scope,
      plus_one: plus_one
    } do
      assert {:ok, updated} =
               Guests.update_person(scope, plus_one, %{"plus_one_status" => "confirmed"})

      assert updated.plus_one_status == :confirmed

      entries =
        LogQuery.for_entity(:person, plus_one.id) |> Enum.reject(&(&1.description =~ "added"))

      assert [entry] = entries
      assert entry.description == "Wannes changed the +1 status of 'Tom': Possible → Confirmed"
    end

    test "want_tier is refused", %{scope: scope, plus_one: plus_one} do
      assert {:error, changeset} = Guests.update_person(scope, plus_one, %{"want_tier" => "no"})
      assert "is inherited from the host" in errors_on(changeset).want_tier
    end

    test "certainty is refused", %{scope: scope, plus_one: plus_one} do
      assert {:error, changeset} =
               Guests.update_person(scope, plus_one, %{"certainty" => "likely"})

      assert "is inherited from the host" in errors_on(changeset).certainty
    end

    test "group_id is refused", %{scope: scope, plus_one: plus_one} do
      {:ok, group} = Guests.create_group(scope, %{"name" => "Family Peeters"})

      assert {:error, changeset} =
               Guests.update_person(scope, plus_one, %{"group_id" => group.id})

      assert "is inherited from the host" in errors_on(changeset).group_id
    end

    test "clearing names on an unnamed-turned-named +1 makes it unnamed again, old display name resolves",
         %{scope: scope, plus_one: plus_one} do
      assert {:ok, updated} =
               Guests.update_person(scope, plus_one, %{"first_name" => "", "last_name" => ""})

      refute Person.name_known?(updated)

      entries =
        LogQuery.for_entity(:person, plus_one.id) |> Enum.reject(&(&1.description =~ "added"))

      assert [entry] = entries
      assert entry.description == "Wannes changed the first name of 'Tom': Tom → none"
    end
  end

  describe "PER-15 — inheritance at read time" do
    setup %{scope: scope} do
      {:ok, host} =
        Guests.create_person(scope, %{
          "first_name" => "Anna",
          "last_name" => "Peeters",
          "want_tier" => "yes",
          "certainty" => "certain"
        })

      {:ok, confirmed} =
        Guests.add_plus_one(scope, host, %{
          "first_name" => "Tom",
          "plus_one_status" => "confirmed"
        })

      {:ok, possible} = Guests.add_plus_one(scope, host, %{"plus_one_status" => "possible"})

      %{host: host, confirmed: confirmed, possible: possible}
    end

    test "a confirmed +1's want tier/certainty follow the host after update_person/3", %{
      scope: scope,
      host: host,
      confirmed: confirmed
    } do
      {:ok, updated_host} = Guests.update_person(scope, host, %{"want_tier" => "maybe"})

      assert PlusOne.want_tier(confirmed, updated_host) == :maybe
      assert PlusOne.certainty(confirmed, updated_host) == :certain
    end

    test "a confirmed +1's want tier follows the host after bulk_update_persons/4", %{
      scope: scope,
      host: host,
      confirmed: confirmed
    } do
      {:ok, [updated_host]} = Guests.bulk_update_persons(scope, [host], :want_tier, :obligated)

      assert PlusOne.want_tier(confirmed, updated_host) == :obligated
    end

    test "list_persons/1 filtered by want_tier follows the host, not the +1's stored column",
         %{scope: scope, host: host, confirmed: confirmed} do
      {:ok, _updated_host} = Guests.update_person(scope, host, %{"want_tier" => "maybe"})

      ids = Guests.list_persons(%{filters: %{want_tier: :maybe}}) |> Enum.map(& &1.id)
      assert host.id in ids
      assert confirmed.id in ids

      # The +1's own `want_tier` column was written "yes" at creation and is never
      # updated (`DR-32`). Filtering by the now-stale "yes" must find nothing: if the
      # filter read the +1's own stored column instead of going through
      # `WeddingPlanner.Guests.PlusOne`, this unit would wrongly still match on "yes"
      # (the unit-inclusion rule is host-or-any-+1, so a stale +1 match alone is enough
      # to leak the whole unit back in).
      stale_ids = Guests.list_persons(%{filters: %{want_tier: :yes}}) |> Enum.map(& &1.id)
      refute host.id in stale_ids
      refute confirmed.id in stale_ids
    end

    test "a possible +1's certainty is the host's", %{
      host: host,
      possible: possible
    } do
      assert PlusOne.certainty(possible, host) == host.certainty
    end

    test "a confirmed +1's certainty follows the host's certainty", %{
      host: host,
      confirmed: confirmed
    } do
      assert PlusOne.certainty(confirmed, host) == :certain
    end
  end

  describe "delete_person/2 — a +1 alone (PER-12)" do
    test "deletes it like any other person, no host cascade", %{scope: scope} do
      {:ok, host} = Guests.create_person(scope, %{"first_name" => "Anna"})
      {:ok, plus_one} = Guests.add_plus_one(scope, host, %{"first_name" => "Tom"})

      assert {:ok, _deleted} = Guests.delete_person(scope, plus_one)

      assert Repo.aggregate(Person, :count) == 1
      assert Guests.get_person!(host.id)
    end
  end

  describe "delete_person/2 — a host with +1s (PER-16)" do
    setup %{scope: scope} do
      {:ok, host} =
        Guests.create_person(scope, %{"first_name" => "Anna", "last_name" => "Peeters"})

      {:ok, tom} =
        Guests.add_plus_one(scope, host, %{"first_name" => "Tom", "last_name" => "Wils"})

      {:ok, unnamed} = Guests.add_plus_one(scope, host, %{})

      %{host: host, tom: tom, unnamed: unnamed}
    end

    test "one summary naming the host and every +1, a child per +1 then the host", %{
      scope: scope,
      host: host,
      tom: tom,
      unnamed: unnamed
    } do
      assert {:ok, _deleted} = Guests.delete_person(scope, host)
      assert Repo.aggregate(Person, :count) == 0

      entries = Repo.all(Entry) |> Enum.reject(&(&1.description =~ "added"))
      {[summary], children} = Enum.split_with(entries, &is_nil(&1.entity_type))

      assert summary.description =~ "Wannes deleted 'Anna Peeters' and 2 +1s:"
      assert summary.description =~ "Tom Wils"
      assert summary.description =~ "+1 of Anna Peeters"

      assert length(children) == 3
      assert Enum.all?(children, &(&1.parent_id == summary.id))

      child_ids = Enum.map(children, & &1.entity_id) |> Enum.sort()
      assert child_ids == Enum.sort([host.id, tom.id, unnamed.id])
    end

    test "singular wording for exactly one +1", %{scope: scope} do
      {:ok, host2} = Guests.create_person(scope, %{"first_name" => "Ben"})
      {:ok, _tom2} = Guests.add_plus_one(scope, host2, %{"first_name" => "Jan"})

      {:ok, _deleted} = Guests.delete_person(scope, host2)

      summary =
        Repo.all(Entry)
        |> Enum.find(&(&1.description =~ "deleted 'Ben'"))

      assert summary.description == "Wannes deleted 'Ben' and 1 +1: Jan"
    end

    test "a host with no +1s keeps the single-entry behaviour", %{scope: scope} do
      {:ok, plain} = Guests.create_person(scope, %{"first_name" => "Chris"})
      {:ok, _deleted} = Guests.delete_person(scope, plain)

      entries = Repo.all(Entry) |> Enum.reject(&(&1.description =~ "added"))
      assert [entry] = Enum.filter(entries, &(&1.entity_id == plain.id))
      assert entry.description == "Wannes deleted 'Chris'"
      assert is_nil(entry.parent_id)
    end

    test "broadcasts {:deleted, id} for the host and every +1", %{
      scope: scope,
      host: host,
      tom: tom,
      unnamed: unnamed
    } do
      Realtime.subscribe(:person)
      {:ok, _deleted} = Guests.delete_person(scope, host)

      host_id = host.id
      tom_id = tom.id
      unnamed_id = unnamed.id

      assert_received {Realtime, :person, {:deleted, ^tom_id}}
      assert_received {Realtime, :person, {:deleted, ^unnamed_id}}
      assert_received {Realtime, :person, {:deleted, ^host_id}}
    end

    test "person_deletion_effects/1 names the +1s beforehand", %{
      host: host,
      tom: tom,
      unnamed: unnamed
    } do
      assert [%{label: label, count: 2}] = Guests.person_deletion_effects(host)
      assert label =~ "Also deletes their 2 +1s:"
      assert label =~ Person.display_name(tom)
      unnamed_with_host = Map.put(unnamed, :host, host)
      assert label =~ Person.display_name(unnamed_with_host)
    end

    test "person_deletion_effects/1 is [] for a +1 and for a host without +1s", %{
      scope: scope,
      tom: tom
    } do
      assert Guests.person_deletion_effects(tom) == []

      {:ok, plain} = Guests.create_person(scope, %{"first_name" => "Chris"})
      assert Guests.person_deletion_effects(plain) == []
    end

    test "bulk delete of a host alone also deletes its +1s and names them", %{
      scope: scope,
      host: host,
      tom: tom,
      unnamed: unnamed
    } do
      assert {:ok, deleted} = Guests.bulk_delete_persons(scope, [host])

      deleted_ids = Enum.map(deleted, & &1.id) |> Enum.sort()
      assert deleted_ids == Enum.sort([host.id, tom.id, unnamed.id])

      summary = Repo.all(Entry) |> Enum.find(&is_nil(&1.entity_type))
      assert summary.description =~ "Wannes deleted 3 people:"
      assert summary.description =~ "Tom Wils"
    end

    test "bulk_deletion_effects/1 names the pulled-in +1s when only the host is selected", %{
      host: host,
      tom: tom,
      unnamed: unnamed
    } do
      assert [%{label: label, count: 2}] = Guests.bulk_deletion_effects([host])
      assert label =~ Person.display_name(tom)
      unnamed_with_host = Map.put(unnamed, :host, host)
      assert label =~ Person.display_name(unnamed_with_host)
    end

    test "bulk delete selecting both host and a +1 does not double-delete", %{
      scope: scope,
      host: host,
      tom: tom,
      unnamed: unnamed
    } do
      assert {:ok, deleted} = Guests.bulk_delete_persons(scope, [host, tom])

      deleted_ids = Enum.map(deleted, & &1.id) |> Enum.sort()
      assert deleted_ids == Enum.sort([host.id, tom.id, unnamed.id])
      assert length(deleted_ids) == 3

      assert Repo.aggregate(Person, :count) == 0
    end

    test "bulk_deletion_effects/1 is [] once every +1 is already in the selection", %{
      host: host,
      tom: tom,
      unnamed: unnamed
    } do
      assert Guests.bulk_deletion_effects([host, tom, unnamed]) == []
    end
  end

  describe "bulk_update_persons/4 skips +1s (PER-15, DR-34)" do
    test "a +1 in the selection is silently skipped, not editable", %{scope: scope} do
      {:ok, host} = Guests.create_person(scope, %{"first_name" => "Anna", "want_tier" => "yes"})
      {:ok, plus_one} = Guests.add_plus_one(scope, host, %{"first_name" => "Tom"})

      assert {:ok, updated} =
               Guests.bulk_update_persons(scope, [host, plus_one], :want_tier, :maybe)

      assert Enum.map(updated, & &1.id) == [host.id]

      summary = Repo.all(Entry) |> Enum.find(&(&1.description =~ "set 1 person"))
      assert summary.description == "Wannes set 1 person to want tier Maybe"

      reloaded_plus_one = Guests.get_person!(plus_one.id)
      assert reloaded_plus_one.want_tier == :yes
    end

    test "a group select-all including the group's +1s still names the group correctly", %{
      scope: scope
    } do
      {:ok, group} = Guests.create_group(scope, %{"name" => "Family Peeters"})

      {:ok, a} =
        Guests.create_person(scope, %{
          "first_name" => "A",
          "group_id" => group.id,
          "want_tier" => "yes"
        })

      {:ok, b} =
        Guests.create_person(scope, %{
          "first_name" => "B",
          "group_id" => group.id,
          "want_tier" => "yes"
        })

      {:ok, plus_one} = Guests.add_plus_one(scope, a, %{"first_name" => "Tom"})

      {:ok, _updated} = Guests.bulk_update_persons(scope, [a, b, plus_one], :want_tier, :maybe)

      summary = Repo.all(Entry) |> Enum.find(&is_nil(&1.entity_type))

      assert summary.description ==
               "Wannes set 2 people in 'Family Peeters' to want tier Maybe"
    end
  end

  describe "list_persons/1 — host units (DR-34)" do
    setup %{scope: scope} do
      {:ok, ben} = Guests.create_person(scope, %{"first_name" => "Ben"})

      {:ok, anna} =
        Guests.create_person(scope, %{"first_name" => "Anna", "last_name" => "Peeters"})

      {:ok, tom} =
        Guests.add_plus_one(scope, anna, %{"first_name" => "Tom", "last_name" => "Wils"})

      {:ok, unnamed} = Guests.add_plus_one(scope, anna, %{})

      %{ben: ben, anna: anna, tom: tom, unnamed: unnamed}
    end

    test "a +1 always directly follows its host in the default sort", %{
      ben: ben,
      anna: anna,
      tom: tom,
      unnamed: unnamed
    } do
      ids = Guests.list_persons() |> Enum.map(& &1.id)
      anna_index = Enum.find_index(ids, &(&1 == anna.id))

      assert Enum.slice(ids, anna_index, 3) |> Enum.sort() ==
               Enum.sort([anna.id, tom.id, unnamed.id])

      assert ben.id in ids
    end

    test "+1s are ordered by id under their host", %{anna: anna, tom: tom, unnamed: unnamed} do
      ids = Guests.list_persons() |> Enum.map(& &1.id)
      anna_index = Enum.find_index(ids, &(&1 == anna.id))

      assert Enum.at(ids, anna_index + 1) == min(tom.id, unnamed.id)
      assert Enum.at(ids, anna_index + 2) == max(tom.id, unnamed.id)
    end

    test "a +1 also follows its host under every other sort attribute", %{anna: anna} do
      for sort <- [:first_name, :last_name, :group, :age_category, :want_tier, :certainty] do
        ids = Guests.list_persons(%{sort: sort}) |> Enum.map(& &1.id)
        anna_index = Enum.find_index(ids, &(&1 == anna.id))
        assert Enum.at(ids, anna_index + 1) != nil, "sort #{inspect(sort)} lost the +1 unit"
      end
    end

    test "filtering by a +1's name returns the whole unit", %{
      anna: anna,
      tom: tom,
      unnamed: unnamed
    } do
      ids = Guests.list_persons(%{filters: %{text: "wils"}}) |> Enum.map(& &1.id)
      assert Enum.sort(ids) == Enum.sort([anna.id, tom.id, unnamed.id])
    end

    test "group filter narrows by the host's group, +1 included", %{scope: scope} do
      {:ok, group} = Guests.create_group(scope, %{"name" => "Family Peeters"})

      {:ok, host} =
        Guests.create_person(scope, %{"first_name" => "Griet", "group_id" => group.id})

      {:ok, plus_one} = Guests.add_plus_one(scope, host, %{"first_name" => "Jef"})

      ids = Guests.list_persons(%{filters: %{group_id: group.id}}) |> Enum.map(& &1.id)
      assert Enum.sort(ids) == Enum.sort([host.id, plus_one.id])
    end

    test "PlusOne.group_id/2 lets a grouped-by-group consumer place a +1 under the host's group",
         %{scope: scope} do
      {:ok, group} = Guests.create_group(scope, %{"name" => "Family Peeters"})

      {:ok, host} =
        Guests.create_person(scope, %{"first_name" => "Griet", "group_id" => group.id})

      {:ok, plus_one} = Guests.add_plus_one(scope, host, %{"first_name" => "Jef"})

      assert PlusOne.group_id(plus_one, host) == group.id
    end
  end

  describe "resolve_person_log_entity/1 — +1s (DR-26 Q9)" do
    test "an unnamed +1 resolves to '+1 of <host>', not a crash or empty text", %{scope: scope} do
      {:ok, host} =
        Guests.create_person(scope, %{"first_name" => "Anna", "last_name" => "Peeters"})

      {:ok, plus_one} = Guests.add_plus_one(scope, host, %{})

      assert {:link, "+1 of Anna Peeters", "/people/" <> _} =
               EntityRef.resolve("person", plus_one.id)
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

  # -- delete_group/2 — headcount presets (PER-07, DR-53) -------------------------------

  describe "delete_group/2 — headcount presets naming the deleted group" do
    setup %{scope: scope} do
      {:ok, group} = Guests.create_group(scope, %{"name" => "Family Peeters"})
      {:ok, other_group} = Guests.create_group(scope, %{"name" => "Other side"})

      {:ok, alone} =
        Presets.create_preset(scope, %{"name" => "Family only", "group_ids" => [group.id]})

      {:ok, two_groups} =
        Presets.create_preset(scope, %{
          "name" => "Both sides",
          "group_ids" => [group.id, other_group.id]
        })

      {:ok, untouched} =
        Presets.create_preset(scope, %{
          "name" => "Other side only",
          "group_ids" => [other_group.id]
        })

      %{
        group: group,
        other_group: other_group,
        alone: alone,
        two_groups: two_groups,
        untouched: untouched
      }
    end

    test "group_deletion_effects/1 lists both presets with the two wordings", %{
      group: group,
      alone: alone,
      two_groups: two_groups
    } do
      effects = Guests.group_deletion_effects(group)

      assert %{label: "Preset '#{alone.name}' will no longer be restricted by group", count: 1} in effects

      assert %{label: "Preset '#{two_groups.name}' stops filtering on this group", count: 1} in effects
    end

    test "delete_group/2 rewrites both presets' group_ids, logs one child entry per preset under the summary, broadcasts both, leaves the untouched one alone",
         %{
           scope: scope,
           group: group,
           other_group: other_group,
           alone: alone,
           two_groups: two_groups,
           untouched: untouched
         } do
      Realtime.subscribe(:headcount_preset)

      {:ok, _deleted} = Guests.delete_group(scope, group)

      reloaded_alone = Presets.get_preset!(alone.id)
      reloaded_two_groups = Presets.get_preset!(two_groups.id)
      reloaded_untouched = Presets.get_preset!(untouched.id)

      assert reloaded_alone.group_ids == []
      assert reloaded_two_groups.group_ids == [other_group.id]
      assert reloaded_untouched.group_ids == [other_group.id]

      summary =
        Repo.all(Entry) |> Enum.find(&(&1.description =~ "deleted group 'Family Peeters'"))

      alone_entry =
        LogQuery.for_entity(:headcount_preset, alone.id)
        |> Enum.find(&(&1.description =~ "group deleted"))

      two_groups_entry =
        LogQuery.for_entity(:headcount_preset, two_groups.id)
        |> Enum.find(&(&1.description =~ "group deleted"))

      assert alone_entry.description ==
               "Wannes removed group 'Family Peeters' from preset 'Family only' (group deleted)"

      assert alone_entry.parent_id == summary.id

      assert two_groups_entry.description ==
               "Wannes removed group 'Family Peeters' from preset 'Both sides' (group deleted)"

      assert two_groups_entry.parent_id == summary.id

      refute LogQuery.for_entity(:headcount_preset, untouched.id)
             |> Enum.any?(&(&1.description =~ "group deleted"))

      assert_received {Realtime, :headcount_preset, {:updated, updated_alone}}
      assert updated_alone.id == alone.id
      assert_received {Realtime, :headcount_preset, {:updated, updated_two_groups}}
      assert updated_two_groups.id == two_groups.id
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
