defmodule WeddingPlanner.Log.SummaryTest do
  @moduledoc """
  `WeddingPlanner.Log.summary/3` (`XC-10`, `DR-98`): one entry with no entity and no
  parent, broadcast like any other entry unless `broadcast: false`.
  """
  use WeddingPlanner.DataCase, async: false

  import WeddingPlanner.OfferFixtures, only: [scope_fixture: 0]

  alias WeddingPlanner.Log
  alias WeddingPlanner.Log.Entry
  alias WeddingPlanner.Realtime

  setup do
    :ok = Realtime.subscribe(:activity_entry)
    %{scope: scope_fixture()}
  end

  test "writes a summary-style entry and broadcasts it by default", %{scope: scope} do
    assert {:ok, %Entry{} = entry} = Log.summary(scope, "Wannes did one big thing")

    assert %Entry{entity_type: nil, entity_id: nil, parent_id: nil} = Repo.get!(Entry, entry.id)
    assert entry.user_id == scope.user.id
    assert entry.description == "Wannes did one big thing"
    assert_receive {Realtime, :activity_entry, {:created, %Entry{id: id}}}
    assert id == entry.id
  end

  test "broadcast: false writes the entry and broadcasts nothing", %{scope: scope} do
    assert {:ok, entry} = Log.summary(scope, "Wannes imported data", broadcast: false)
    assert Repo.get!(Entry, entry.id).description == "Wannes imported data"
    refute_receive {Realtime, :activity_entry, _}
  end

  test "an empty description is a changeset error", %{scope: scope} do
    assert {:error, %Ecto.Changeset{}} = Log.summary(scope, "", broadcast: false)
    assert Repo.aggregate(Entry, :count) == 0
  end
end
