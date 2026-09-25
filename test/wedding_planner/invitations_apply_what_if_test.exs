defmodule WeddingPlanner.InvitationsApplyWhatIfTest do
  @moduledoc """
  `WeddingPlanner.Invitations.apply_what_if/2` — task 89's what-if screen's *Apply*, one
  logged bulk write of invitation statuses (`BUD-20`, `INVT-01`, `PER-13`, `XC-10`,
  `XC-12`, `DR-83`).
  """
  use WeddingPlanner.DataCase, async: false

  alias WeddingPlanner.Accounts.Scope
  alias WeddingPlanner.Accounts.User
  alias WeddingPlanner.Events
  alias WeddingPlanner.Guests
  alias WeddingPlanner.Invitations
  alias WeddingPlanner.Invitations.Invitation
  alias WeddingPlanner.Log.Entry
  alias WeddingPlanner.Log.Query, as: LogQuery
  alias WeddingPlanner.Realtime

  setup do
    user = insert_user!("Wannes")
    scope = Scope.for_user(user)

    {:ok, anna} = Guests.create_person(scope, %{"first_name" => "Anna", "last_name" => "Peeters"})
    {:ok, bert} = Guests.create_person(scope, %{"first_name" => "Bert", "last_name" => "Peeters"})
    {:ok, dinner} = Events.create_event(scope, %{"name" => "Dinner"})
    {:ok, reception} = Events.create_event(scope, %{"name" => "Reception"})

    %{scope: scope, anna: anna, bert: bert, dinner: dinner, reception: reception}
  end

  # -- test 1 --------------------------------------------------------------------------

  test "applies several cells across two events for two persons as one logged action", %{
    scope: scope,
    anna: anna,
    bert: bert,
    dinner: dinner,
    reception: reception
  } do
    {:ok, _} = Invitations.set_invitation_status(scope, bert, dinner, :invited)
    {:ok, _} = Invitations.set_invitation_status(scope, anna, reception, :planned)

    cells = [
      %{person: anna, event: dinner, status: :invited},
      %{person: bert, event: dinner, status: :accepted},
      %{person: anna, event: reception, status: :not_invited}
    ]

    assert {:ok, changed} = Invitations.apply_what_if(scope, cells)
    assert length(changed) == 3

    assert %Invitation{status: :invited} =
             Repo.get_by!(Invitation, person_id: anna.id, event_id: dinner.id)

    assert %Invitation{status: :accepted} =
             Repo.get_by!(Invitation, person_id: bert.id, event_id: dinner.id)

    refute Repo.get_by(Invitation, person_id: anna.id, event_id: reception.id)

    summary = Repo.all(Entry) |> Enum.find(&is_nil(&1.entity_type))

    assert summary.description ==
             "Wannes applied a what-if: 3 invitation changes for 2 people"

    children = LogQuery.children(summary.id)
    assert length(children) == 3
    assert Enum.all?(children, &(&1.entity_type == "person"))

    descriptions = Enum.map(children, & &1.description)

    assert "Wannes changed the invitation for 'Anna Peeters' to 'Dinner': not invited → invited" in descriptions

    assert "Wannes changed the invitation for 'Bert Peeters' to 'Dinner': invited → accepted" in descriptions

    assert "Wannes changed the invitation for 'Anna Peeters' to 'Reception': planned → not invited" in descriptions

    assert %{person: %{id: anna_id}, event: %{id: dinner_id}, from: :not_invited, to: :invited} =
             Enum.find(changed, &(&1.person.id == anna.id and &1.event.id == dinner.id))

    assert anna_id == anna.id
    assert dinner_id == dinner.id

    assert %{from: :invited, to: :accepted} =
             Enum.find(changed, &(&1.person.id == bert.id and &1.event.id == dinner.id))

    assert %{from: :planned, to: :not_invited} =
             Enum.find(changed, &(&1.person.id == anna.id and &1.event.id == reception.id))
  end

  # -- test 2 --------------------------------------------------------------------------

  describe "no-op cells" do
    test "a cell already at its target is skipped: no child, not counted in the summary", %{
      scope: scope,
      anna: anna,
      bert: bert,
      dinner: dinner
    } do
      {:ok, _} = Invitations.set_invitation_status(scope, bert, dinner, :invited)

      cells = [
        # no-op: bert is already invited to dinner
        %{person: bert, event: dinner, status: :invited},
        %{person: anna, event: dinner, status: :invited}
      ]

      assert {:ok, changed} = Invitations.apply_what_if(scope, cells)
      assert length(changed) == 1
      assert [%{person: %{id: id}, from: :not_invited, to: :invited}] = changed
      assert id == anna.id

      summary = Repo.all(Entry) |> Enum.find(&is_nil(&1.entity_type))
      assert summary.description == "Wannes applied a what-if: 1 invitation change for 1 person"

      children = LogQuery.children(summary.id)
      assert length(children) == 1
    end

    test "every cell a no-op → {:ok, []}, no entry at all", %{
      scope: scope,
      anna: anna,
      bert: bert,
      dinner: dinner
    } do
      {:ok, _} = Invitations.set_invitation_status(scope, anna, dinner, :invited)
      {:ok, _} = Invitations.set_invitation_status(scope, bert, dinner, :planned)

      cells = [
        %{person: anna, event: dinner, status: :invited},
        %{person: bert, event: dinner, status: :planned}
      ]

      entries_before = Repo.all(Entry)
      assert Invitations.apply_what_if(scope, cells) == {:ok, []}
      assert Repo.all(Entry) == entries_before
    end
  end

  # -- test 3 --------------------------------------------------------------------------

  test "a cell for a +1 is refused whole: {:error, :plus_one}, nothing written, no entry", %{
    scope: scope,
    anna: anna,
    dinner: dinner
  } do
    {:ok, plus_one} = Guests.add_plus_one(scope, anna, %{})

    cells = [
      %{person: anna, event: dinner, status: :invited},
      %{person: plus_one, event: dinner, status: :invited}
    ]

    entries_before = Repo.all(Entry)
    assert Invitations.apply_what_if(scope, cells) == {:error, :plus_one}

    refute Repo.get_by(Invitation, person_id: anna.id, event_id: dinner.id)
    refute Repo.get_by(Invitation, person_id: plus_one.id, event_id: dinner.id)
    assert Repo.all(Entry) == entries_before
  end

  # -- test 4 --------------------------------------------------------------------------

  describe "stale references" do
    test "a cell for a deleted person is refused whole: {:error, :stale}, nothing written", %{
      scope: scope,
      anna: anna,
      bert: bert,
      dinner: dinner
    } do
      {:ok, _} = Guests.delete_person(scope, anna)

      cells = [
        %{person: bert, event: dinner, status: :invited},
        %{person: anna, event: dinner, status: :invited}
      ]

      assert Invitations.apply_what_if(scope, cells) == {:error, :stale}
      refute Repo.get_by(Invitation, person_id: bert.id, event_id: dinner.id)
    end

    test "a cell for a deleted event is refused whole: {:error, :stale}, nothing written", %{
      scope: scope,
      anna: anna,
      bert: bert,
      dinner: dinner,
      reception: reception
    } do
      {:ok, _} = Events.delete_event(scope, reception)

      cells = [
        %{person: anna, event: dinner, status: :invited},
        %{person: bert, event: reception, status: :invited}
      ]

      assert Invitations.apply_what_if(scope, cells) == {:error, :stale}
      refute Repo.get_by(Invitation, person_id: anna.id, event_id: dinner.id)
    end
  end

  # -- test 5 --------------------------------------------------------------------------

  test "broadcasts :created/:updated/:deleted only for written rows, after the call returns",
       %{scope: scope, anna: anna, bert: bert, dinner: dinner, reception: reception} do
    {:ok, _} = Invitations.set_invitation_status(scope, bert, dinner, :invited)
    {:ok, _} = Invitations.set_invitation_status(scope, anna, reception, :planned)

    cells = [
      # created
      %{person: anna, event: dinner, status: :invited},
      # updated
      %{person: bert, event: dinner, status: :accepted},
      # deleted
      %{person: anna, event: reception, status: :not_invited},
      # no-op: skipped, no broadcast
      %{person: bert, event: reception, status: :not_invited}
    ]

    Realtime.subscribe(:invitation)

    assert {:ok, _changed} = Invitations.apply_what_if(scope, cells)

    # After the call returns: the broadcasts already happened, so `assert_received`
    # (not `assert_receive`) proves they arrived before this line, not after it.
    assert_received {Realtime, :invitation, {:created, %Invitation{person_id: id, event_id: eid}}}
    assert id == anna.id
    assert eid == dinner.id

    assert_received {Realtime, :invitation,
                     {:updated, %Invitation{person_id: id2, event_id: eid2}}}

    assert id2 == bert.id
    assert eid2 == dinner.id

    refute Repo.get_by(Invitation, person_id: anna.id, event_id: reception.id)
    assert_received {Realtime, :invitation, {:deleted, _deleted_id}}

    # Exactly those three — the fourth (no-op) cell produced no fourth broadcast.
    refute_received {Realtime, :invitation, _}
  end

  test "a later cell's write failure rolls back earlier writes in the same call — and their broadcasts never went out",
       %{scope: scope, anna: anna, bert: bert, dinner: dinner, reception: reception} do
    Realtime.subscribe(:invitation)
    entries_before = Repo.all(Entry)

    cells = [
      # would succeed on its own
      %{person: anna, event: dinner, status: :invited},
      # would succeed on its own
      %{person: bert, event: dinner, status: :invited},
      # not a real status: raises while being written, aborting the whole action
      %{person: anna, event: reception, status: :not_a_real_status}
    ]

    assert_raise MatchError, fn -> Invitations.apply_what_if(scope, cells) end

    # The whole action is one transaction (`Log.action/3`): nothing from it survives.
    refute Repo.get_by(Invitation, person_id: anna.id, event_id: dinner.id)
    refute Repo.get_by(Invitation, person_id: bert.id, event_id: dinner.id)
    assert Repo.all(Entry) == entries_before

    # And since a broadcast must only ever happen after commit (`XC-01`/`XC-02`; the
    # `Log` moduledoc's own invariant), nothing was broadcast for the two cells that
    # *did* get written before the rollback — a subscriber must never see a row
    # announced that then turns out never to have existed.
    refute_received {Realtime, :invitation, _}
  end

  # -- test 6 --------------------------------------------------------------------------

  test "the child entry's from is the database's current status, not the draft's stale idea of it",
       %{scope: scope, anna: anna, dinner: dinner} do
    {:ok, _} = Invitations.set_invitation_status(scope, anna, dinner, :invited)

    # The draft was built while anna was "invited"; another user changes it before Apply.
    cells = [%{person: anna, event: dinner, status: :accepted}]
    {:ok, _} = Invitations.set_invitation_status(scope, anna, dinner, :declined)

    assert {:ok, [%{from: from, to: :accepted}]} = Invitations.apply_what_if(scope, cells)
    assert from == :declined

    summary = Repo.all(Entry) |> Enum.find(&is_nil(&1.entity_type))
    child = LogQuery.children(summary.id) |> List.first()

    assert child.description ==
             "Wannes changed the invitation for 'Anna Peeters' to 'Dinner': declined → accepted"
  end

  defp insert_user!(display_name) do
    %User{} |> User.changeset(%{display_name: display_name}) |> Repo.insert!()
  end
end
