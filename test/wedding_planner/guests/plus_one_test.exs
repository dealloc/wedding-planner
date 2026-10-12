defmodule WeddingPlanner.Guests.PlusOneTest do
  @moduledoc """
  `WeddingPlanner.Guests.PlusOne` — the pure PER-15 inheritance helper. Bare structs
  only, no database (see the module's own moduledoc and `guests_test.exs` for the
  integrated, "does it actually follow the host after an update" behaviour).
  """
  use ExUnit.Case, async: true

  doctest WeddingPlanner.Guests.PlusOne

  alias WeddingPlanner.Guests.Person
  alias WeddingPlanner.Guests.PlusOne

  describe "want_tier/2 (PER-15)" do
    test "a non-+1 keeps its own want tier, host ignored" do
      person = %Person{host_id: nil, want_tier: :maybe}
      host = %Person{want_tier: :yes}

      assert PlusOne.want_tier(person, host) == :maybe
    end

    test "a +1 always follows the host's want tier, own column ignored" do
      host = %Person{want_tier: :obligated}
      plus_one = %Person{host_id: 1, want_tier: :no, plus_one_status: :confirmed}

      assert PlusOne.want_tier(plus_one, host) == :obligated
    end
  end

  describe "certainty/2 (PER-15, HC-05)" do
    test "a non-+1 keeps its own certainty, host ignored" do
      person = %Person{host_id: nil, certainty: :uncertain}
      host = %Person{certainty: :certain}

      assert PlusOne.certainty(person, host) == :uncertain
    end

    test "a confirmed +1 follows the host's certainty" do
      host = %Person{certainty: :certain}
      plus_one = %Person{host_id: 1, plus_one_status: :confirmed}

      assert PlusOne.certainty(plus_one, host) == :certain
    end

    test "a possible +1's certainty is the host's, like a confirmed one" do
      for host_certainty <- Person.certainties() do
        host = %Person{certainty: host_certainty}
        plus_one = %Person{host_id: 1, plus_one_status: :possible}

        assert PlusOne.certainty(plus_one, host) == host_certainty
      end
    end
  end

  describe "group_id/2 (DR-32: a +1 has no group of its own)" do
    test "a non-+1 keeps its own group_id" do
      person = %Person{host_id: nil, group_id: 3}
      host = %Person{group_id: 9}

      assert PlusOne.group_id(person, host) == 3
    end

    test "a +1 always uses the host's group_id, even if its own is somehow set" do
      host = %Person{group_id: 9}
      plus_one = %Person{host_id: 1, group_id: nil}

      assert PlusOne.group_id(plus_one, host) == 9
    end

    test "a +1 under an ungrouped host has no group either" do
      host = %Person{group_id: nil}
      plus_one = %Person{host_id: 1, group_id: nil}

      assert PlusOne.group_id(plus_one, host) == nil
    end
  end

  describe "/1 convenience versions with :host preloaded" do
    test "a non-+1 needs no preload" do
      person = %Person{host_id: nil, want_tier: :maybe, certainty: :likely, group_id: 5}

      assert PlusOne.want_tier(person) == :maybe
      assert PlusOne.certainty(person) == :likely
      assert PlusOne.group_id(person) == 5
    end

    test "a +1 with :host preloaded resolves through it" do
      host = %Person{id: 1, want_tier: :yes, certainty: :certain, group_id: 7}
      plus_one = %Person{host_id: 1, plus_one_status: :confirmed, host: host}

      assert PlusOne.want_tier(plus_one) == :yes
      assert PlusOne.certainty(plus_one) == :certain
      assert PlusOne.group_id(plus_one) == 7
    end

    test "a +1 without :host preloaded raises ArgumentError" do
      plus_one = %Person{id: 42, host_id: 1, plus_one_status: :possible}

      assert_raise ArgumentError, ~r/needs :host preloaded/, fn ->
        PlusOne.want_tier(plus_one)
      end

      assert_raise ArgumentError, ~r/needs :host preloaded/, fn ->
        PlusOne.certainty(plus_one)
      end

      assert_raise ArgumentError, ~r/needs :host preloaded/, fn ->
        PlusOne.group_id(plus_one)
      end
    end
  end
end
