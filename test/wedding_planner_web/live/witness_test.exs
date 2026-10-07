defmodule WeddingPlannerWeb.Live.WitnessTest do
  @moduledoc """
  Witnesses (`docs/modules/guests-and-events.md` `PER-20`..`PER-23`): at most two per
  user, always *accepted* for every event (including later ones), locked everywhere.
  """
  use WeddingPlannerWeb.ConnCase, async: true

  import Phoenix.LiveViewTest

  alias WeddingPlanner.Accounts.Passkey
  alias WeddingPlanner.Accounts.Scope
  alias WeddingPlanner.Accounts.User
  alias WeddingPlanner.Events
  alias WeddingPlanner.Guests
  alias WeddingPlanner.Invitations
  alias WeddingPlanner.Repo

  setup %{conn: conn} do
    user = insert_user!("Wannes")
    other = insert_user!("Partner")
    scope = Scope.for_user(user)
    {:ok, dinner} = Events.create_event(scope, %{"name" => "Dinner"})
    {:ok, party} = Events.create_event(scope, %{"name" => "Party"})

    person = fn name ->
      {:ok, p} = Guests.create_person(scope, %{"first_name" => name})
      p
    end

    %{
      conn: log_in_user(conn, user),
      scope: scope,
      user: user,
      other: other,
      dinner: dinner,
      party: party,
      person: person
    }
  end

  defp status(person, event) do
    person |> Invitations.statuses_for_person() |> Map.new() |> Map.get(event.id, :not_invited)
  end

  test "designating makes the person obligated, certain and accepted everywhere",
       %{scope: scope, user: user, dinner: dinner, party: party, person: person} do
    anna = person.("Anna")
    assert {:ok, anna} = Guests.set_witness(scope, anna, user.id)

    assert anna.want_tier == :obligated
    assert anna.certainty == :certain
    assert status(anna, dinner) == :accepted
    assert status(anna, party) == :accepted
  end

  test "events created later also get the witness accepted",
       %{scope: scope, user: user, person: person} do
    anna = person.("Anna")
    {:ok, anna} = Guests.set_witness(scope, anna, user.id)
    {:ok, brunch} = Events.create_event(scope, %{"name" => "Brunch"})
    assert status(anna, brunch) == :accepted
  end

  test "at most two per user; the other user has their own two",
       %{scope: scope, user: user, other: other, person: person} do
    {:ok, _} = Guests.set_witness(scope, person.("A"), user.id)
    {:ok, _} = Guests.set_witness(scope, person.("B"), user.id)
    assert {:error, :limit} = Guests.set_witness(scope, person.("C"), user.id)
    assert {:ok, _} = Guests.set_witness(scope, person.("C"), other.id)
  end

  test "a +1 cannot be a witness", %{scope: scope, user: user, person: person} do
    {:ok, plus_one} = Guests.add_plus_one(scope, person.("Host"), %{})
    assert {:error, :plus_one} = Guests.set_witness(scope, plus_one, user.id)
  end

  test "the status is locked: single cell, bulk and what-if", %{
    scope: scope,
    user: user,
    dinner: dinner,
    person: person
  } do
    {:ok, anna} = Guests.set_witness(scope, person.("Anna"), user.id)

    assert {:error, :witness} = Invitations.set_invitation_status(scope, anna, dinner, :declined)
    assert {:ok, []} = Invitations.bulk_set_invitation_status(scope, [anna], dinner, :declined)

    assert {:error, :witness} =
             Invitations.apply_what_if(scope, [
               %{person: anna, event: dinner, status: :not_invited}
             ])

    assert status(anna, dinner) == :accepted
  end

  test "tier and certainty are fixed, and bulk updates skip witnesses", %{
    scope: scope,
    user: user,
    person: person
  } do
    {:ok, anna} = Guests.set_witness(scope, person.("Anna"), user.id)

    assert {:error, changeset} = Guests.update_person(scope, anna, %{"want_tier" => "maybe"})
    assert %{want_tier: [_]} = WeddingPlanner.DataCase.errors_on(changeset)

    assert {:ok, []} = Guests.bulk_update_persons(scope, [anna], :certainty, :uncertain)
    assert Guests.get_person!(anna.id).certainty == :certain
  end

  test "removing the designation unlocks but keeps invitations", %{
    scope: scope,
    user: user,
    dinner: dinner,
    person: person
  } do
    {:ok, anna} = Guests.set_witness(scope, person.("Anna"), user.id)
    {:ok, anna} = Guests.set_witness(scope, anna, nil)

    refute anna.witness_of_id
    assert status(anna, dinner) == :accepted
    assert {:ok, _} = Invitations.set_invitation_status(scope, anna, dinner, :declined)
  end

  test "the matrix shows locked cells for a witness; the person page sets the designation",
       %{conn: conn, scope: scope, user: user, dinner: dinner, person: person} do
    anna = person.("Anna")
    {:ok, view, _html} = live(conn, ~p"/people/#{anna.id}")

    view
    |> form("#person-witness-form", witness: %{"user_id" => to_string(user.id)})
    |> render_change()

    assert Guests.get_person!(anna.id).witness_of_id == user.id

    {:ok, matrix, _html} = live(conn, ~p"/invitations")
    assert has_element?(matrix, "#cell-#{anna.id}-#{dinner.id}-locked")
    refute has_element?(matrix, "#cell-#{anna.id}-#{dinner.id}")
    _ = scope
  end

  defp insert_user!(display_name) do
    user = %User{} |> User.changeset(%{display_name: display_name}) |> Repo.insert!()
    # `Users.assignable?/1` — the couple are the users with a registered passkey (DR-22).
    %Passkey{user_id: user.id, sign_count: 0}
    |> Passkey.registration_changeset(%{
      credential_id: :crypto.strong_rand_bytes(16),
      public_key: :crypto.strong_rand_bytes(16),
      name: "#{display_name}'s device",
      registered_at: DateTime.utc_now() |> DateTime.truncate(:second)
    })
    |> Repo.insert!()

    user
  end
end
