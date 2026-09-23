defmodule WeddingPlanner.LogTest do
  @moduledoc """
  `docs/04-cross-cutting.md` `XC-10` through `XC-13`: the write-through activity log
  service, tested before any domain module exists to write through it.
  """
  use WeddingPlanner.DataCase, async: true

  alias WeddingPlanner.Accounts.Passkey
  alias WeddingPlanner.Accounts.Scope
  alias WeddingPlanner.Accounts.User
  alias WeddingPlanner.Log
  alias WeddingPlanner.Log.Entry
  alias WeddingPlanner.Realtime

  setup do
    {:ok, user} = %User{} |> User.changeset(%{display_name: "Wannes"}) |> Repo.insert()
    %{user: user, scope: Scope.for_user(user)}
  end

  test "XC-10, NFR-21: a single entry records the user, a UTC timestamp, the entity and the description",
       %{user: user, scope: scope} do
    before = DateTime.utc_now() |> DateTime.truncate(:second)

    assert {:ok, entry} =
             Log.entry(scope, {:invoice, 42}, "Wannes marked invoice 'Venue deposit' as paid")

    assert entry.user_id == user.id
    assert entry.entity_type == "invoice"
    assert entry.entity_id == 42
    assert entry.description == "Wannes marked invoice 'Venue deposit' as paid"
    assert %DateTime{time_zone: "Etc/UTC"} = entry.inserted_at
    assert DateTime.compare(entry.inserted_at, before) in [:gt, :eq]
    assert is_nil(entry.parent_id)
  end

  test "XC-10: a transition description records both the old and the new value", %{scope: scope} do
    assert {:ok, entry} =
             Log.entry(
               scope,
               {:invitation, 7},
               "Invitation for Anna Peeters to Dinner: invited → accepted"
             )

    assert entry.description == "Invitation for Anna Peeters to Dinner: invited → accepted"
  end

  test "XC-12: a bulk action produces exactly one summary plus one child per affected entity, each referencing it",
       %{scope: scope} do
    assert {:ok, :done} =
             Log.action(
               scope,
               "Wannes set 4 people in 'Family Peeters' to invited for Reception",
               fn ->
                 for id <- 1..4 do
                   {:ok, _} = Log.entry(scope, {:person, id}, "Person #{id} set to invited")
                 end

                 :done
               end
             )

    entries = Repo.all(Entry)
    assert length(entries) == 5

    {[summary], children} = Enum.split_with(entries, &is_nil(&1.parent_id))
    assert length(children) == 4

    assert summary.description ==
             "Wannes set 4 people in 'Family Peeters' to invited for Reception"

    assert is_nil(summary.entity_type)
    assert is_nil(summary.entity_id)
    assert Enum.all?(children, &(&1.parent_id == summary.id))
    assert Enum.sort(Enum.map(children, & &1.entity_id)) == [1, 2, 3, 4]
  end

  test "XC-12: a failure inside the action callback rolls back the summary and every child written so far",
       %{scope: scope} do
    assert_raise RuntimeError, "boom", fn ->
      Log.action(scope, "Bulk update that will fail", fn ->
        {:ok, _} = Log.entry(scope, {:person, 1}, "Person 1 set to invited")
        raise "boom"
      end)
    end

    assert Repo.aggregate(Entry, :count) == 0
  end

  test "XC-12: entries written outside of an action are not linked to a stale parent", %{
    scope: scope
  } do
    {:ok, _} = Log.action(scope, "First bulk action", fn -> :ok end)
    {:ok, standalone} = Log.entry(scope, {:person, 99}, "Unrelated single entry")

    assert is_nil(standalone.parent_id)
  end

  test "XC-10: an entry for a deleted entity still renders", %{user: user, scope: scope} do
    {:ok, passkey} =
      %Passkey{user_id: user.id}
      |> Passkey.registration_changeset(%{
        credential_id: <<1, 2, 3>>,
        public_key: <<4, 5, 6>>,
        name: "Old phone",
        registered_at: DateTime.utc_now() |> DateTime.truncate(:second)
      })
      |> Repo.insert()

    {:ok, entry} = Log.entry(scope, {:passkey, passkey.id}, "Wannes revoked passkey 'Old phone'")

    Repo.delete!(passkey)

    assert {:text, label} = Log.resolve(entry)
    assert is_binary(label)
  end

  test "XC-12: a summarising entry has no entity to resolve", %{scope: scope} do
    {:ok, :ok} = Log.action(scope, "Bulk action with no entries", fn -> :ok end)
    summary = Repo.one!(from e in Entry, where: is_nil(e.parent_id))

    assert is_nil(Log.resolve(summary))
  end

  test "XC-01: a single entry broadcasts {:created, entry} on :activity_entry after the insert",
       %{scope: scope} do
    Realtime.subscribe(:activity_entry)

    {:ok, entry} =
      Log.entry(scope, {:invoice, 42}, "Wannes marked invoice 'Venue deposit' as paid")

    assert_received {Realtime, :activity_entry, {:created, ^entry}}
  end

  test "XC-01, XC-12: an action broadcasts the summary then each child, only after the transaction commits",
       %{scope: scope} do
    Realtime.subscribe(:activity_entry)

    {:ok, :done} =
      Log.action(
        scope,
        "Wannes set 2 people in 'Family Peeters' to invited for Reception",
        fn ->
          refute_received {Realtime, :activity_entry, _}

          {:ok, _} = Log.entry(scope, {:person, 1}, "Person 1 set to invited")
          {:ok, _} = Log.entry(scope, {:person, 2}, "Person 2 set to invited")

          # Still inside the transaction: nothing has been broadcast yet, even though
          # the rows are already written (and visible to this same connection).
          refute_received {Realtime, :activity_entry, _}

          :done
        end
      )

    assert_received {Realtime, :activity_entry, {:created, summary}}
    assert is_nil(summary.entity_type)

    assert_received {Realtime, :activity_entry, {:created, child1}}
    assert child1.entity_id == 1
    assert child1.parent_id == summary.id

    assert_received {Realtime, :activity_entry, {:created, child2}}
    assert child2.entity_id == 2
    assert child2.parent_id == summary.id

    refute_received {Realtime, :activity_entry, _}
  end

  test "XC-01, XC-12: a raising action delivers no broadcast at all", %{scope: scope} do
    Realtime.subscribe(:activity_entry)

    assert_raise RuntimeError, "boom", fn ->
      Log.action(scope, "Bulk update that will fail", fn ->
        {:ok, _} = Log.entry(scope, {:person, 1}, "Person 1 set to invited")
        raise "boom"
      end)
    end

    refute_received {Realtime, :activity_entry, _}
  end

  test "XC-13: the log is read-only, there is no update or delete API" do
    Code.ensure_loaded!(Log)
    Code.ensure_loaded!(Entry)

    refute function_exported?(Log, :update, 2)
    refute function_exported?(Log, :update, 3)
    refute function_exported?(Log, :delete, 1)
    refute function_exported?(Log, :delete, 2)
    refute function_exported?(Entry, :update_changeset, 2)
    refute function_exported?(Entry, :delete_changeset, 1)
    refute function_exported?(Entry, :delete_changeset, 2)
  end
end
