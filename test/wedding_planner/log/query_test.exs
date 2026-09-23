defmodule WeddingPlanner.Log.QueryTest do
  @moduledoc """
  `WeddingPlanner.Log.Query`, the read-side companion to `WeddingPlanner.Log` (task 20;
  `docs/04-cross-cutting.md` `XC-11`, `XC-12`). Exercises the global log's top-level
  listing/filtering and the per-entity `for_entity/2` completeness guarantee directly,
  separate from the LiveView tests that exercise the same behaviour through the UI.
  """
  use WeddingPlanner.DataCase, async: true

  alias WeddingPlanner.Accounts.Scope
  alias WeddingPlanner.Accounts.User
  alias WeddingPlanner.Log
  alias WeddingPlanner.Log.Query

  setup do
    wannes = insert_user!("Wannes")
    partner = insert_user!("Partner")
    %{wannes: wannes, partner: partner, wannes_scope: Scope.for_user(wannes)}
  end

  describe "list/1" do
    test "returns top-level entries newest first, never a bulk child", %{
      wannes_scope: scope
    } do
      {:ok, first} = Log.entry(scope, {:person, 1}, "First entry")

      {:ok, :done} =
        Log.action(scope, "Bulk summary", fn ->
          {:ok, _} = Log.entry(scope, {:person, 2}, "Child")
          :done
        end)

      {:ok, last} = Log.entry(scope, {:person, 3}, "Last entry")

      entries = Query.list()

      assert [newest, summary, oldest] = entries
      assert newest.id == last.id
      assert summary.description == "Bulk summary"
      assert is_nil(summary.entity_type)
      assert oldest.id == first.id
      assert Enum.all?(entries, &is_nil(&1.parent_id))
    end

    test "preloads :user", %{wannes_scope: scope, wannes: wannes} do
      {:ok, _} = Log.entry(scope, {:person, 1}, "Entry")
      assert [%{user: %User{id: id}}] = Query.list()
      assert id == wannes.id
    end

    test "filters by user_id", %{wannes_scope: wannes_scope, partner: partner} do
      partner_scope = Scope.for_user(partner)
      {:ok, wannes_entry} = Log.entry(wannes_scope, {:person, 1}, "By Wannes")
      {:ok, _partner_entry} = Log.entry(partner_scope, {:person, 2}, "By Partner")

      assert [entry] = Query.list(%{user_id: wannes_scope.user.id})
      assert entry.id == wannes_entry.id
    end

    test "filters by entity_type, excluding bulk summaries", %{wannes_scope: scope} do
      {:ok, person_entry} = Log.entry(scope, {:person, 1}, "Person entry")
      {:ok, _invoice_entry} = Log.entry(scope, {:invoice, 1}, "Invoice entry")

      {:ok, :done} =
        Log.action(scope, "Bulk", fn ->
          {:ok, _} = Log.entry(scope, {:person, 2}, "Child")
          :done
        end)

      assert [entry] = Query.list(%{entity_type: "person"})
      assert entry.id == person_entry.id
    end

    test "filters by an inclusive from/to UTC range", %{wannes_scope: scope} do
      {:ok, entry} = Log.entry(scope, {:person, 1}, "In range")

      from = DateTime.add(entry.inserted_at, -60, :second)
      to = DateTime.add(entry.inserted_at, 60, :second)
      assert [%{id: id}] = Query.list(%{from: from, to: to})
      assert id == entry.id

      too_late_from = DateTime.add(entry.inserted_at, 60, :second)
      assert Query.list(%{from: too_late_from}) == []

      too_early_to = DateTime.add(entry.inserted_at, -60, :second)
      assert Query.list(%{to: too_early_to}) == []
    end
  end

  describe "children/1 and children_counts/1" do
    test "children/1 lists a summary's children in write order", %{wannes_scope: scope} do
      {:ok, :done} =
        Log.action(scope, "Bulk", fn ->
          {:ok, _} = Log.entry(scope, {:person, 1}, "First child")
          {:ok, _} = Log.entry(scope, {:person, 2}, "Second child")
          :done
        end)

      [summary] = Query.list()
      assert [first, second] = Query.children(summary.id)
      assert first.description == "First child"
      assert second.description == "Second child"
    end

    test "children_counts/1 counts per summary, omitting summaries with no children", %{
      wannes_scope: scope
    } do
      {:ok, :done} =
        Log.action(scope, "Bulk with two", fn ->
          {:ok, _} = Log.entry(scope, {:person, 1}, "a")
          {:ok, _} = Log.entry(scope, {:person, 2}, "b")
          :done
        end)

      {:ok, :empty} = Log.action(scope, "Bulk with none", fn -> :empty end)

      [with_two, with_none] =
        Query.list() |> Enum.sort_by(&(&1.description == "Bulk with none"))

      counts = Query.children_counts([with_two.id, with_none.id])
      assert counts[with_two.id] == 2
      refute Map.has_key?(counts, with_none.id)
      assert Query.children_counts([]) == %{}
    end
  end

  describe "for_entity/2" do
    test "includes both standalone entries and bulk children for the same entity", %{
      wannes_scope: scope
    } do
      {:ok, _standalone} = Log.entry(scope, {:person, 42}, "Standalone")

      {:ok, :done} =
        Log.action(scope, "Bulk", fn ->
          {:ok, _} = Log.entry(scope, {:person, 42}, "Child for 42")
          {:ok, _} = Log.entry(scope, {:person, 99}, "Child for 99")
          :done
        end)

      entries = Query.for_entity(:person, 42)
      descriptions = Enum.map(entries, & &1.description) |> Enum.sort()

      assert descriptions == ["Child for 42", "Standalone"]
      refute Enum.any?(entries, &(&1.description == "Child for 99"))
    end

    test "accepts an atom or a string type interchangeably", %{wannes_scope: scope} do
      {:ok, _} = Log.entry(scope, {:person, 1}, "Entry")

      assert length(Query.for_entity(:person, 1)) == 1
      assert length(Query.for_entity("person", 1)) == 1
    end
  end

  describe "list_users/0 and list_entity_types/0" do
    test "list_users/0 returns every user ordered by display name", %{
      wannes: wannes,
      partner: partner
    } do
      assert Enum.map(Query.list_users(), & &1.id) |> Enum.sort() ==
               Enum.sort([wannes.id, partner.id])
    end

    test "list_entity_types/0 returns distinct, alphabetical, non-nil entity types", %{
      wannes_scope: scope
    } do
      {:ok, _} = Log.entry(scope, {:person, 1}, "a")
      {:ok, _} = Log.entry(scope, {:person, 2}, "b")
      {:ok, _} = Log.entry(scope, {:invoice, 1}, "c")
      {:ok, :done} = Log.action(scope, "Bulk", fn -> :done end)

      assert Query.list_entity_types() == ["invoice", "person"]
    end
  end

  describe "matches_filters?/2" do
    test "matches an entry against user_id, entity_type and range filters independently", %{
      wannes_scope: scope,
      partner: partner
    } do
      {:ok, entry} = Log.entry(scope, {:person, 1}, "Entry")

      assert Query.matches_filters?(entry, %{})
      assert Query.matches_filters?(entry, %{user_id: scope.user.id})
      refute Query.matches_filters?(entry, %{user_id: partner.id})
      assert Query.matches_filters?(entry, %{entity_type: "person"})
      refute Query.matches_filters?(entry, %{entity_type: "invoice"})

      refute Query.matches_filters?(entry, %{from: DateTime.add(entry.inserted_at, 60, :second)})
      assert Query.matches_filters?(entry, %{from: DateTime.add(entry.inserted_at, -60, :second)})
    end

    test "a bulk summary never matches an active entity_type filter", %{wannes_scope: scope} do
      {:ok, :done} = Log.action(scope, "Bulk", fn -> :done end)
      [summary] = Query.list()

      refute Query.matches_filters?(summary, %{entity_type: "person"})
      assert Query.matches_filters?(summary, %{})
    end
  end

  defp insert_user!(display_name) do
    %User{} |> User.changeset(%{display_name: display_name}) |> Repo.insert!()
  end
end
