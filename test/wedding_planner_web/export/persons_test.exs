defmodule WeddingPlannerWeb.Export.PersonsTest do
  @moduledoc """
  `WeddingPlannerWeb.Export.Persons` (`D-29`, `PER-11`, `PER-13`, `PER-14`, `PER-15`,
  `DR-88`) — pure, in-memory: no database, structs built by hand.
  """
  use ExUnit.Case, async: true

  alias WeddingPlanner.Events.Event
  alias WeddingPlanner.Guests.Group
  alias WeddingPlanner.Guests.Person
  alias WeddingPlanner.Invitations.Invitation
  alias WeddingPlanner.Invitations.PlusOneOptOut
  alias WeddingPlanner.Valuation.Snapshot
  alias WeddingPlannerWeb.Export.Persons

  @today ~D[2026-09-25]

  # Fixed column indices in `Persons.table/2`'s row shape (before the event columns).
  @first_name 0
  @last_name 1
  @display_name 2
  @group 3
  @group_type 4
  @host 5
  @plus_one_status 6
  @age_category 7
  @want_tier 8
  @certainty 9
  @first_event 10

  defp host(attrs) do
    struct!(
      %Person{
        id: 1,
        first_name: "Anna",
        last_name: "Peeters",
        age_category: :adult,
        want_tier: :yes,
        certainty: :certain,
        group_id: nil,
        notes: nil
      },
      attrs
    )
  end

  defp plus_one(attrs) do
    struct!(
      %Person{
        id: 2,
        host_id: 1,
        first_name: "Tom",
        last_name: "Wils",
        age_category: :adult,
        want_tier: :no,
        certainty: :uncertain,
        plus_one_status: :confirmed,
        group_id: 99,
        notes: nil
      },
      attrs
    )
  end

  defp table_for(persons, snapshot_attrs) do
    snapshot =
      struct!(
        %Snapshot{events: [], groups: [], invitations: [], plus_one_opt_outs: []},
        Map.put(snapshot_attrs, :persons, persons)
      )

    Persons.table(%{persons: persons, snapshot: snapshot}, @today)
  end

  test "headers, event columns in snapshot.events order" do
    ceremony = %Event{id: 10, name: "Ceremony"}
    reception = %Event{id: 20, name: "Reception"}
    anna = host([])

    table = table_for([anna], %{events: [ceremony, reception]})

    assert table.stem == "persons"

    assert table.headers == [
             "First name",
             "Last name",
             "Display name",
             "Group",
             "Group type",
             "Host",
             "+1 status",
             "Age category",
             "Want tier",
             "Certainty",
             "Ceremony",
             "Reception",
             "Notes"
           ]
  end

  test "a host row has no Host/+1 status and its own age/want/certainty" do
    anna = host([])
    [row] = table_for([anna], %{}).rows

    assert Enum.at(row, @first_name) == "Anna"
    assert Enum.at(row, @last_name) == "Peeters"
    assert Enum.at(row, @display_name) == "Anna Peeters"
    assert Enum.at(row, @host) == nil
    assert Enum.at(row, @plus_one_status) == nil
    assert Enum.at(row, @age_category) == "Adult"
    assert Enum.at(row, @want_tier) == "Yes"
    assert Enum.at(row, @certainty) == "Certain"
  end

  describe "FP-92d — a +1's inherited values win over its own stored columns" do
    test "group, want tier and certainty come from the host, not the +1's own row" do
      family = %Group{id: 5, name: "Family Peeters", type_label: "Household"}
      anna = host(group_id: 5)
      tom = plus_one(plus_one_status: :possible)

      [_anna_row, tom_row] = table_for([anna, tom], %{groups: [family]}).rows

      # `tom`'s own stored columns say group 99 / want :no / certainty :uncertain — the
      # export must show Anna's group and want tier, and the *possible* certainty cap
      # (uncertain), never Tom's own stored values (which happen to coincide with
      # "uncertain" here on purpose, so the fail-proof — reverting to the +1's own
      # columns — is checked via the group/want-tier assertions, which cannot coincide).
      assert Enum.at(tom_row, @group) == "Family Peeters"
      assert Enum.at(tom_row, @group_type) == "Household"
      assert Enum.at(tom_row, @want_tier) == "Yes"
      assert Enum.at(tom_row, @certainty) == "Uncertain"
    end

    test "a confirmed +1 is not capped — it shows the host's own certainty" do
      anna = host(certainty: :certain)
      tom = plus_one(plus_one_status: :confirmed, certainty: :certain)

      [_anna_row, tom_row] = table_for([anna, tom], %{}).rows

      assert Enum.at(tom_row, @certainty) == "Certain"
    end

    test "host/+1 status columns for the +1 itself" do
      anna = host([])
      tom = plus_one(plus_one_status: :possible)

      [_anna_row, tom_row] = table_for([anna, tom], %{}).rows

      assert Enum.at(tom_row, @host) == "Anna Peeters"
      assert Enum.at(tom_row, @plus_one_status) == "Possible"
    end
  end

  describe "FP-92e — effective invitation status" do
    test "host accepted, +1 with no opt-out: both Accepted" do
      reception = %Event{id: 10, name: "Reception"}
      anna = host([])
      tom = plus_one([])
      invitations = [%Invitation{person_id: 1, event_id: 10, status: :accepted}]

      [anna_row, tom_row] =
        table_for([anna, tom], %{events: [reception], invitations: invitations}).rows

      assert Enum.at(anna_row, @first_event) == "Accepted"
      assert Enum.at(tom_row, @first_event) == "Accepted"
    end

    test "+1 opted out: Declined, even though the host accepted" do
      reception = %Event{id: 10, name: "Reception"}
      anna = host([])
      tom = plus_one([])
      invitations = [%Invitation{person_id: 1, event_id: 10, status: :accepted}]
      opt_outs = [%PlusOneOptOut{person_id: 2, event_id: 10}]

      [anna_row, tom_row] =
        table_for([anna, tom], %{
          events: [reception],
          invitations: invitations,
          plus_one_opt_outs: opt_outs
        }).rows

      assert Enum.at(anna_row, @first_event) == "Accepted"
      assert Enum.at(tom_row, @first_event) == "Declined"
    end

    test "host not invited: both Not invited, even when the +1 has an opt-out (PER-14)" do
      reception = %Event{id: 10, name: "Reception"}
      anna = host([])
      tom = plus_one([])
      opt_outs = [%PlusOneOptOut{person_id: 2, event_id: 10}]

      [anna_row, tom_row] =
        table_for([anna, tom], %{events: [reception], plus_one_opt_outs: opt_outs}).rows

      assert Enum.at(anna_row, @first_event) == "Not invited"
      assert Enum.at(tom_row, @first_event) == "Not invited"
    end
  end

  test "an unnamed +1 has blank first/last name and display name '+1 of <host>'" do
    anna = host([])
    unnamed = plus_one(first_name: nil, last_name: nil)

    [_anna_row, tom_row] = table_for([anna, unnamed], %{}).rows

    assert Enum.at(tom_row, @first_name) == nil
    assert Enum.at(tom_row, @last_name) == nil
    assert Enum.at(tom_row, @display_name) == "+1 of Anna Peeters"
  end

  test "no money is exported, so there is no Currency column" do
    anna = host([])
    table = table_for([anna], %{})
    refute "Currency" in table.headers
  end
end
