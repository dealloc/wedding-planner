defmodule WeddingPlanner.InvitationsTest do
  @moduledoc """
  `WeddingPlanner.Invitations` — the data layer for `docs/modules/guests-and-events.md`
  `INVT-01`–`INVT-04`, `PER-13`, `PER-14` (`DR-37`, `DR-38`, task 44).

  `async: false`: several tests mutate `:wedding_planner, :event_reference_providers`
  (global app env — `config/config.exs` is orchestrator-owned, so this task's two
  providers are installed here via `Application.put_env`, restored on exit, see
  `install_invitation_providers!/0`).

  G1–G3 are proven twice: `WeddingPlanner.Invitations.EffectiveTest` covers them with
  bare in-memory structs (no database); the tests below, tagged `@tag example:`, cover
  the same three through this context's real writes plus `Effective.index/3` over rows
  actually loaded back from storage.
  """
  use WeddingPlanner.DataCase, async: false

  alias WeddingPlanner.Accounts.Scope
  alias WeddingPlanner.Accounts.User
  alias WeddingPlanner.Events
  alias WeddingPlanner.Guests
  alias WeddingPlanner.Invitations
  alias WeddingPlanner.Invitations.Effective
  alias WeddingPlanner.Invitations.Invitation
  alias WeddingPlanner.Invitations.PlusOneOptOut
  alias WeddingPlanner.Log.Entry
  alias WeddingPlanner.Log.Query, as: LogQuery
  alias WeddingPlanner.Realtime

  setup do
    user = insert_user!("Wannes")
    %{user: user, scope: Scope.for_user(user)}
  end

  # -- set_invitation_status/4 (INVT-01, DR-37, DR-38) ----------------------------------

  describe "set_invitation_status/4" do
    setup %{scope: scope} do
      {:ok, anna} =
        Guests.create_person(scope, %{"first_name" => "Anna", "last_name" => "Peeters"})

      {:ok, dinner} = Events.create_event(scope, %{"couple_attends" => false, "name" => "Dinner"})
      %{anna: anna, dinner: dinner}
    end

    test "sets a status on a not-yet-invited person, logs and broadcasts :created", %{
      scope: scope,
      anna: anna,
      dinner: dinner
    } do
      Realtime.subscribe(:invitation)

      assert {:ok, invitation} = Invitations.set_invitation_status(scope, anna, dinner, :invited)
      assert invitation.status == :invited
      assert invitation.person_id == anna.id
      assert invitation.event_id == dinner.id

      entries = LogQuery.for_entity(:person, anna.id) |> Enum.reject(&(&1.description =~ "added"))
      assert [entry] = entries

      assert entry.description ==
               "Wannes changed the invitation for 'Anna Peeters' to 'Dinner': not invited → invited"

      invitation_id = invitation.id
      assert_received {Realtime, :invitation, {:created, %Invitation{id: ^invitation_id}}}
    end

    test "changes an existing status, logs old -> new, broadcasts :updated", %{
      scope: scope,
      anna: anna,
      dinner: dinner
    } do
      {:ok, _} = Invitations.set_invitation_status(scope, anna, dinner, :invited)
      Realtime.subscribe(:invitation)

      assert {:ok, updated} = Invitations.set_invitation_status(scope, anna, dinner, :accepted)
      assert updated.status == :accepted

      entries = LogQuery.for_entity(:person, anna.id)

      assert Enum.any?(
               entries,
               &(&1.description ==
                   "Wannes changed the invitation for 'Anna Peeters' to 'Dinner': invited → accepted")
             )

      updated_id = updated.id

      assert_received {Realtime, :invitation,
                       {:updated, %Invitation{id: ^updated_id, status: :accepted}}}
    end

    test "clears a status back to not invited by deleting the row, logs and broadcasts :deleted",
         %{scope: scope, anna: anna, dinner: dinner} do
      {:ok, invitation} = Invitations.set_invitation_status(scope, anna, dinner, :invited)
      Realtime.subscribe(:invitation)

      assert {:ok, nil} = Invitations.set_invitation_status(scope, anna, dinner, :not_invited)
      refute Repo.get(Invitation, invitation.id)

      entries = LogQuery.for_entity(:person, anna.id)

      assert Enum.any?(
               entries,
               &(&1.description ==
                   "Wannes changed the invitation for 'Anna Peeters' to 'Dinner': invited → not invited")
             )

      id = invitation.id
      assert_received {Realtime, :invitation, {:deleted, ^id}}
    end

    test "no-op setting the same status again: no entry, no broadcast", %{
      scope: scope,
      anna: anna,
      dinner: dinner
    } do
      {:ok, invitation} = Invitations.set_invitation_status(scope, anna, dinner, :invited)
      Realtime.subscribe(:invitation)
      count_before = length(LogQuery.for_entity(:person, anna.id))

      assert {:ok, ^invitation} = Invitations.set_invitation_status(scope, anna, dinner, :invited)

      assert length(LogQuery.for_entity(:person, anna.id)) == count_before
      refute_received {Realtime, :invitation, _}
    end

    test "setting :not_invited on a person with no row is a no-op: no entry, no broadcast", %{
      scope: scope,
      anna: anna,
      dinner: dinner
    } do
      Realtime.subscribe(:invitation)
      count_before = length(LogQuery.for_entity(:person, anna.id))

      assert {:ok, nil} = Invitations.set_invitation_status(scope, anna, dinner, :not_invited)

      assert length(LogQuery.for_entity(:person, anna.id)) == count_before
      refute_received {Realtime, :invitation, _}
    end

    test "{:error, :plus_one} for a +1, no row written", %{
      scope: scope,
      anna: anna,
      dinner: dinner
    } do
      {:ok, plus_one} = Guests.add_plus_one(scope, anna, %{"first_name" => "Tom"})

      assert {:error, :plus_one} =
               Invitations.set_invitation_status(scope, plus_one, dinner, :invited)

      assert Repo.aggregate(Invitation, :count) == 0
    end
  end

  # -- set_opt_out/4 (PER-13, PER-14) ----------------------------------------------------

  describe "set_opt_out/4" do
    setup %{scope: scope} do
      {:ok, anna} =
        Guests.create_person(scope, %{"first_name" => "Anna", "last_name" => "Peeters"})

      {:ok, plus_one} = Guests.add_plus_one(scope, anna, %{})
      {:ok, dinner} = Events.create_event(scope, %{"couple_attends" => false, "name" => "Dinner"})
      %{anna: anna, plus_one: plus_one, dinner: dinner}
    end

    test "opts out, logs and broadcasts :created", %{
      scope: scope,
      plus_one: plus_one,
      dinner: dinner
    } do
      Realtime.subscribe(:plus_one_opt_out)

      assert {:ok, opt_out} = Invitations.set_opt_out(scope, plus_one, dinner, true)
      assert opt_out.person_id == plus_one.id
      assert opt_out.event_id == dinner.id

      entries = LogQuery.for_entity(:person, plus_one.id)

      assert Enum.any?(
               entries,
               &(&1.description == "Wannes opted '+1 of Anna Peeters' out of 'Dinner'")
             )

      id = opt_out.id
      assert_received {Realtime, :plus_one_opt_out, {:created, %PlusOneOptOut{id: ^id}}}
    end

    test "removes an opt-out, logs and broadcasts :deleted", %{
      scope: scope,
      plus_one: plus_one,
      dinner: dinner
    } do
      {:ok, opt_out} = Invitations.set_opt_out(scope, plus_one, dinner, true)
      Realtime.subscribe(:plus_one_opt_out)

      assert {:ok, nil} = Invitations.set_opt_out(scope, plus_one, dinner, false)
      refute Repo.get(PlusOneOptOut, opt_out.id)

      entries = LogQuery.for_entity(:person, plus_one.id)

      assert Enum.any?(
               entries,
               &(&1.description ==
                   "Wannes removed the opt-out of '+1 of Anna Peeters' for 'Dinner'")
             )

      id = opt_out.id
      assert_received {Realtime, :plus_one_opt_out, {:deleted, ^id}}
    end

    test "opting out an already-opted-out +1 is a no-op: no entry, no broadcast", %{
      scope: scope,
      plus_one: plus_one,
      dinner: dinner
    } do
      {:ok, opt_out} = Invitations.set_opt_out(scope, plus_one, dinner, true)
      Realtime.subscribe(:plus_one_opt_out)
      count_before = length(LogQuery.for_entity(:person, plus_one.id))

      assert {:ok, ^opt_out} = Invitations.set_opt_out(scope, plus_one, dinner, true)

      assert length(LogQuery.for_entity(:person, plus_one.id)) == count_before
      refute_received {Realtime, :plus_one_opt_out, _}
    end

    test "clearing a non-existent opt-out is a no-op: no entry, no broadcast", %{
      scope: scope,
      plus_one: plus_one,
      dinner: dinner
    } do
      Realtime.subscribe(:plus_one_opt_out)
      count_before = length(LogQuery.for_entity(:person, plus_one.id))

      assert {:ok, nil} = Invitations.set_opt_out(scope, plus_one, dinner, false)

      assert length(LogQuery.for_entity(:person, plus_one.id)) == count_before
      refute_received {Realtime, :plus_one_opt_out, _}
    end

    test "{:error, :not_a_plus_one} for a regular person, no row written", %{
      scope: scope,
      anna: anna,
      dinner: dinner
    } do
      assert {:error, :not_a_plus_one} = Invitations.set_opt_out(scope, anna, dinner, true)
      assert Repo.aggregate(PlusOneOptOut, :count) == 0
    end

    test "PER-14: opt-out settable while the host is not invited, retained but without effect",
         %{scope: scope, anna: anna, plus_one: plus_one, dinner: dinner} do
      assert {:ok, %PlusOneOptOut{}} = Invitations.set_opt_out(scope, plus_one, dinner, true)

      lookup =
        Effective.index(
          [anna, plus_one],
          Invitations.list_invitations(),
          Invitations.list_opt_outs()
        )

      assert Effective.status(lookup, plus_one, dinner.id) == :not_invited
      assert Effective.opted_out?(lookup, plus_one, dinner.id)
    end
  end

  # -- bulk_set_invitation_status/4 (PER-04, XC-12, G5) ----------------------------------

  describe "bulk_set_invitation_status/4" do
    setup %{scope: scope} do
      {:ok, event} =
        Events.create_event(scope, %{"couple_attends" => false, "name" => "Reception"})

      {:ok, group} = Guests.create_group(scope, %{"name" => "Family Peeters"})

      persons =
        for name <- ["Anna", "Bert", "Carla", "Dries"] do
          {:ok, p} =
            Guests.create_person(scope, %{"first_name" => name, "group_id" => group.id})

          p
        end

      {:ok, plus_one} = Guests.add_plus_one(scope, List.first(persons), %{})

      %{event: event, group: group, persons: persons, plus_one: plus_one}
    end

    @tag example: "G5"
    test "bulk-sets a whole group — one row per person, each separately editable afterwards",
         %{scope: scope, event: event, persons: persons} do
      assert {:ok, changed} =
               Invitations.bulk_set_invitation_status(scope, persons, event, :invited)

      assert length(changed) == 4

      for person <- persons do
        assert %Invitation{status: :invited} =
                 Repo.get_by!(Invitation, person_id: person.id, event_id: event.id)
      end

      summary = Repo.all(Entry) |> Enum.find(&is_nil(&1.entity_type))

      assert summary.description ==
               "Wannes set 4 people in 'Family Peeters' to invited for Reception"

      children = LogQuery.children(summary.id)
      assert length(children) == 4
      assert Enum.all?(children, &(&1.entity_type == "person"))

      # G5: each row is separately editable afterwards.
      [anna | _] = persons

      assert {:ok, %Invitation{status: :accepted}} =
               Invitations.set_invitation_status(scope, anna, event, :accepted)

      for person <- Enum.drop(persons, 1) do
        assert %Invitation{status: :invited} =
                 Repo.get_by!(Invitation, person_id: person.id, event_id: event.id)
      end
    end

    test "a mixed (not whole-group) selection uses the plain wording", %{
      scope: scope,
      event: event,
      persons: persons
    } do
      [anna, bert | _rest] = persons

      assert {:ok, changed} =
               Invitations.bulk_set_invitation_status(scope, [anna, bert], event, :invited)

      assert length(changed) == 2

      summary = Repo.all(Entry) |> Enum.find(&is_nil(&1.entity_type))
      assert summary.description == "Wannes set 2 people to invited for Reception"
    end

    test "+1s in the selection are skipped silently", %{
      scope: scope,
      event: event,
      persons: persons,
      plus_one: plus_one
    } do
      assert {:ok, changed} =
               Invitations.bulk_set_invitation_status(
                 scope,
                 persons ++ [plus_one],
                 event,
                 :invited
               )

      refute plus_one.id in Enum.map(changed, & &1.id)
      refute Repo.get_by(Invitation, person_id: plus_one.id, event_id: event.id)
    end

    test "persons already at the target status are skipped silently", %{
      scope: scope,
      event: event,
      persons: persons
    } do
      [anna, bert | rest] = persons
      {:ok, _} = Invitations.set_invitation_status(scope, bert, event, :invited)

      assert {:ok, changed} =
               Invitations.bulk_set_invitation_status(scope, [anna, bert | rest], event, :invited)

      changed_ids = Enum.map(changed, & &1.id)
      assert bert.id not in changed_ids
      assert anna.id in changed_ids
    end

    test ":not_invited deletes rows for the changed persons", %{
      scope: scope,
      event: event,
      persons: persons
    } do
      {:ok, _} = Invitations.bulk_set_invitation_status(scope, persons, event, :invited)

      assert {:ok, changed} =
               Invitations.bulk_set_invitation_status(scope, persons, event, :not_invited)

      assert length(changed) == 4

      for person <- persons do
        refute Repo.get_by(Invitation, person_id: person.id, event_id: event.id)
      end
    end
  end

  # -- bulk_status_preview/3 --------------------------------------------------------------

  describe "bulk_status_preview/3" do
    test "counts changing, overwriting RSVPs and skipped +1s", %{scope: scope} do
      {:ok, event} =
        Events.create_event(scope, %{"couple_attends" => false, "name" => "Reception"})

      {:ok, anna} = Guests.create_person(scope, %{"first_name" => "Anna"})
      {:ok, bert} = Guests.create_person(scope, %{"first_name" => "Bert"})
      {:ok, carla} = Guests.create_person(scope, %{"first_name" => "Carla"})
      {:ok, plus_one} = Guests.add_plus_one(scope, anna, %{})

      {:ok, _} = Invitations.set_invitation_status(scope, bert, event, :accepted)
      {:ok, _} = Invitations.set_invitation_status(scope, carla, event, :invited)

      preview =
        Invitations.bulk_status_preview([anna, bert, carla, plus_one], event, :invited)

      assert preview == %{changing: 2, overwriting_rsvps: 1, skipped_plus_ones: 1}
    end
  end

  # -- EVT-05 providers -------------------------------------------------------------------

  describe "event_invitation_reference/1 and event_opt_out_reference/1 (EVT-05)" do
    test "nil when nothing references the event", %{scope: scope} do
      {:ok, event} = Events.create_event(scope, %{"couple_attends" => false, "name" => "Dinner"})

      assert Invitations.event_invitation_reference(event) == nil
      assert Invitations.event_opt_out_reference(event) == nil
    end

    test "labels and counts once invitations/opt-outs exist", %{scope: scope} do
      {:ok, event} = Events.create_event(scope, %{"couple_attends" => false, "name" => "Dinner"})
      {:ok, anna} = Guests.create_person(scope, %{"first_name" => "Anna"})
      {:ok, bert} = Guests.create_person(scope, %{"first_name" => "Bert"})
      {:ok, plus_one} = Guests.add_plus_one(scope, anna, %{})

      {:ok, _} = Invitations.set_invitation_status(scope, anna, event, :invited)
      {:ok, _} = Invitations.set_invitation_status(scope, bert, event, :invited)
      {:ok, _} = Invitations.set_opt_out(scope, plus_one, event, true)

      assert Invitations.event_invitation_reference(event) == %{label: "2 invitations", count: 2}
      assert Invitations.event_opt_out_reference(event) == %{label: "1 +1 opt-out", count: 1}
    end
  end

  # -- event deletion (EVT-05, DR-38) ------------------------------------------------------

  describe "event deletion removes invitations/opt-outs" do
    setup %{scope: scope} do
      install_invitation_providers!()

      {:ok, event} = Events.create_event(scope, %{"couple_attends" => false, "name" => "Dinner"})

      {:ok, anna} =
        Guests.create_person(scope, %{"first_name" => "Anna", "last_name" => "Peeters"})

      {:ok, plus_one} = Guests.add_plus_one(scope, anna, %{})

      {:ok, invitation} = Invitations.set_invitation_status(scope, anna, event, :accepted)
      {:ok, opt_out} = Invitations.set_opt_out(scope, plus_one, event, true)

      %{event: event, anna: anna, plus_one: plus_one, invitation: invitation, opt_out: opt_out}
    end

    test "affected_references/1 lists both providers beforehand", %{event: event} do
      assert Events.affected_references(event) == [
               %{label: "1 invitation", count: 1},
               %{label: "1 +1 opt-out", count: 1}
             ]
    end

    test "deletes both rows, one child entry per affected person, and still deletes the event",
         %{
           scope: scope,
           event: event,
           invitation: invitation,
           opt_out: opt_out
         } do
      assert {:ok, deleted} = Events.delete_event(scope, event)
      assert deleted.id == event.id
      assert_raise Ecto.NoResultsError, fn -> Events.get_event!(event.id) end

      refute Repo.get(Invitation, invitation.id)
      refute Repo.get(PlusOneOptOut, opt_out.id)

      summary =
        Repo.all(Entry)
        |> Enum.find(&(is_nil(&1.entity_type) and &1.description =~ "deleted event 'Dinner'"))

      children = LogQuery.children(summary.id)

      assert Enum.any?(
               children,
               &(&1.description ==
                   "Wannes removed the invitation for 'Anna Peeters' to 'Dinner' (accepted; event deleted)")
             )

      assert Enum.any?(
               children,
               &(&1.description ==
                   "Wannes removed the opt-out of '+1 of Anna Peeters' for 'Dinner' (event deleted)")
             )

      # One child per affected person, plus the event's own "deleted event" entry
      # (also a child of the same summary).
      assert Enum.count(children, &(&1.entity_type == "person")) == 2
      assert Enum.count(children, &(&1.entity_type == "event")) == 1
    end

    test "broadcasts {:deleted, id} for each removed row on its own resource", %{
      scope: scope,
      event: event,
      invitation: invitation,
      opt_out: opt_out
    } do
      Realtime.subscribe(:invitation)
      Realtime.subscribe(:plus_one_opt_out)

      {:ok, _} = Events.delete_event(scope, event)

      invitation_id = invitation.id
      opt_out_id = opt_out.id
      assert_received {Realtime, :invitation, {:deleted, ^invitation_id}}
      assert_received {Realtime, :plus_one_opt_out, {:deleted, ^opt_out_id}}
    end
  end

  # -- person deletion removes invitations/opt-outs (DR-38) -------------------------------

  describe "person deletion removes invitations/opt-outs" do
    test "a regular person: invitations named in effects and the delete entry", %{scope: scope} do
      {:ok, anna} =
        Guests.create_person(scope, %{"first_name" => "Anna", "last_name" => "Peeters"})

      {:ok, event1} = Events.create_event(scope, %{"couple_attends" => false, "name" => "Dinner"})
      {:ok, event2} = Events.create_event(scope, %{"couple_attends" => false, "name" => "Party"})
      {:ok, _} = Invitations.set_invitation_status(scope, anna, event1, :invited)
      {:ok, _} = Invitations.set_invitation_status(scope, anna, event2, :accepted)

      assert [%{label: "Also removes 2 invitations", count: 2}] =
               Guests.person_deletion_effects(anna)

      assert {:ok, _} = Guests.delete_person(scope, anna)
      assert Repo.aggregate(Invitation, :count) == 0

      entry =
        Repo.all(Entry) |> Enum.find(&(&1.entity_id == anna.id and &1.description =~ "deleted"))

      assert entry.description == "Wannes deleted 'Anna Peeters' (2 invitations removed)"
    end

    test "a +1 alone: its opt-out named in effects and the delete entry", %{scope: scope} do
      {:ok, anna} = Guests.create_person(scope, %{"first_name" => "Anna"})
      {:ok, plus_one} = Guests.add_plus_one(scope, anna, %{})
      {:ok, event} = Events.create_event(scope, %{"couple_attends" => false, "name" => "Dinner"})
      {:ok, _} = Invitations.set_opt_out(scope, plus_one, event, true)

      assert [%{label: "Also removes 1 +1 opt-out", count: 1}] =
               Guests.person_deletion_effects(plus_one)

      assert {:ok, _} = Guests.delete_person(scope, plus_one)
      assert Repo.aggregate(PlusOneOptOut, :count) == 0

      entry =
        Repo.all(Entry)
        |> Enum.find(&(&1.entity_id == plus_one.id and &1.description =~ "deleted"))

      assert entry.description =~ "(1 +1 opt-out removed)"
    end

    # Fail-proof (c): remove `Invitations.delete_for_persons/1`'s call from
    # `Guests.delete_host_with_plus_ones/3` and this fails with a constraint error —
    # the opt-out row would still reference the +1 when its `:restrict` FK tries to
    # block the +1's own delete.
    test "a host with +1s: the host's invitations and the +1's opt-outs both go", %{scope: scope} do
      {:ok, host} =
        Guests.create_person(scope, %{"first_name" => "Anna", "last_name" => "Peeters"})

      {:ok, plus_one} = Guests.add_plus_one(scope, host, %{"first_name" => "Tom"})
      {:ok, event} = Events.create_event(scope, %{"couple_attends" => false, "name" => "Dinner"})
      {:ok, _} = Invitations.set_invitation_status(scope, host, event, :accepted)
      {:ok, _} = Invitations.set_opt_out(scope, plus_one, event, true)

      effects = Guests.person_deletion_effects(host)
      assert Enum.any?(effects, &(&1.label == "Also removes 1 invitation"))
      assert Enum.any?(effects, &(&1.label == "Also removes 1 +1 opt-out"))

      assert {:ok, _} = Guests.delete_person(scope, host)
      assert Repo.aggregate(Invitation, :count) == 0
      assert Repo.aggregate(PlusOneOptOut, :count) == 0

      host_entry =
        Repo.all(Entry) |> Enum.find(&(&1.entity_id == host.id and &1.description =~ "deleted"))

      assert host_entry.description == "Wannes deleted 'Anna Peeters' (1 invitation removed)"

      plus_one_entry =
        Repo.all(Entry)
        |> Enum.find(&(&1.entity_id == plus_one.id and &1.description =~ "deleted"))

      assert plus_one_entry.description =~ "(1 +1 opt-out removed)"
    end

    test "bulk_delete_persons/2 and bulk_deletion_effects/1 also remove/name them", %{
      scope: scope
    } do
      {:ok, host} = Guests.create_person(scope, %{"first_name" => "Anna"})
      {:ok, plus_one} = Guests.add_plus_one(scope, host, %{})
      {:ok, event} = Events.create_event(scope, %{"couple_attends" => false, "name" => "Dinner"})
      {:ok, _} = Invitations.set_invitation_status(scope, host, event, :invited)
      {:ok, _} = Invitations.set_opt_out(scope, plus_one, event, true)

      effects = Guests.bulk_deletion_effects([host])
      assert Enum.any?(effects, &(&1.label == "Also removes 1 invitation"))
      assert Enum.any?(effects, &(&1.label == "Also removes 1 +1 opt-out"))

      assert {:ok, _} = Guests.bulk_delete_persons(scope, [host])
      assert Repo.aggregate(Invitation, :count) == 0
      assert Repo.aggregate(PlusOneOptOut, :count) == 0
    end
  end

  # -- G1-G3, through real storage (mirrors WeddingPlanner.Invitations.EffectiveTest) -----

  describe "normative examples through real storage" do
    setup %{scope: scope} do
      {:ok, anna} =
        Guests.create_person(scope, %{"first_name" => "Anna", "last_name" => "Peeters"})

      {:ok, plus_one} = Guests.add_plus_one(scope, anna, %{})
      {:ok, dinner} = Events.create_event(scope, %{"couple_attends" => false, "name" => "Dinner"})
      {:ok, party} = Events.create_event(scope, %{"couple_attends" => false, "name" => "Party"})

      %{anna: anna, plus_one: plus_one, dinner: dinner, party: party}
    end

    @tag example: "G1"
    test "host accepted, unnamed +1 with no opt-out attends (G1)", %{
      scope: scope,
      anna: anna,
      plus_one: plus_one,
      dinner: dinner
    } do
      {:ok, _} = Invitations.set_invitation_status(scope, anna, dinner, :accepted)

      lookup =
        Effective.index(
          [anna, plus_one],
          Invitations.list_invitations(),
          Invitations.list_opt_outs()
        )

      assert Effective.status(lookup, anna, dinner.id) == :accepted
      assert Effective.status(lookup, plus_one, dinner.id) == :accepted
    end

    @tag example: "G2"
    test "G1, plus the +1 opts out: host attends, +1 declines (G2)", %{
      scope: scope,
      anna: anna,
      plus_one: plus_one,
      dinner: dinner
    } do
      {:ok, _} = Invitations.set_invitation_status(scope, anna, dinner, :accepted)
      {:ok, _} = Invitations.set_opt_out(scope, plus_one, dinner, true)

      lookup =
        Effective.index(
          [anna, plus_one],
          Invitations.list_invitations(),
          Invitations.list_opt_outs()
        )

      assert Effective.status(lookup, anna, dinner.id) == :accepted
      assert Effective.status(lookup, plus_one, dinner.id) == :declined
    end

    @tag example: "G3"
    test "host declined for Party: +1 declines too, even with no opt-out (G3)", %{
      scope: scope,
      anna: anna,
      plus_one: plus_one,
      party: party
    } do
      {:ok, _} = Invitations.set_invitation_status(scope, anna, party, :declined)

      lookup =
        Effective.index(
          [anna, plus_one],
          Invitations.list_invitations(),
          Invitations.list_opt_outs()
        )

      assert Effective.status(lookup, anna, party.id) == :declined
      assert Effective.status(lookup, plus_one, party.id) == :declined
    end
  end

  # -- private ------------------------------------------------------------------------------

  # `config/config.exs` is orchestrator-owned (this task's report hands back the exact two
  # lines) — until then, `Events.affected_references/1`/`delete_event/2`'s transactional
  # path only sees these providers if a test installs them itself. `async: false` on this
  # whole module is what makes mutating this global safe.
  defp install_invitation_providers! do
    original = Application.get_env(:wedding_planner, :event_reference_providers, [])

    # config/config.exs registers these once task 44 lands; only add what's missing so the
    # providers never appear twice.
    wanted = [&Invitations.event_invitation_reference/1, &Invitations.event_opt_out_reference/1]

    Application.put_env(
      :wedding_planner,
      :event_reference_providers,
      original ++ Enum.reject(wanted, &(&1 in original))
    )

    on_exit(fn ->
      Application.put_env(:wedding_planner, :event_reference_providers, original)
    end)
  end

  defp insert_user!(display_name) do
    %User{} |> User.changeset(%{display_name: display_name}) |> Repo.insert!()
  end
end
