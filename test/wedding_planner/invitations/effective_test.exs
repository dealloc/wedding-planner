defmodule WeddingPlanner.Invitations.EffectiveTest do
  @moduledoc """
  `WeddingPlanner.Invitations.Effective` — the pure `PER-13`/`PER-14` rule. Bare
  structs/maps only, no database (see `WeddingPlanner.InvitationsTest` for the
  context-backed variant of G1–G3, tagged `@tag example:`, that proves the same
  examples through real storage).
  """
  use ExUnit.Case, async: true

  doctest WeddingPlanner.Invitations.Effective

  alias WeddingPlanner.Invitations.Effective

  @dinner 10
  @party 11

  defp person(id, host_id \\ nil), do: %{id: id, host_id: host_id}

  # G1: host accepted, unnamed +1, no opt-out -> +1 effectively attending.
  test "a host's accepted status carries over to its +1 with no opt-out (G1)" do
    anna = person(1)
    plus_one = person(2, 1)

    lookup =
      Effective.index(
        [anna, plus_one],
        [%{person_id: 1, event_id: @dinner, status: :accepted}],
        []
      )

    assert Effective.status(lookup, anna, @dinner) == :accepted
    assert Effective.status(lookup, plus_one, @dinner) == :accepted
  end

  # G2: G1 + the +1 opts out -> host still accepted, +1 declined.
  test "an opted-out +1 counts as declined even though its host is accepted (G2)" do
    anna = person(1)
    plus_one = person(2, 1)

    lookup =
      Effective.index(
        [anna, plus_one],
        [%{person_id: 1, event_id: @dinner, status: :accepted}],
        [%{person_id: 2, event_id: @dinner}]
      )

    assert Effective.status(lookup, anna, @dinner) == :accepted
    assert Effective.status(lookup, plus_one, @dinner) == :declined
    assert Effective.opted_out?(lookup, plus_one, @dinner)
  end

  # G3: host declined -> +1 declined too, even with no opt-out at all.
  test "a declined host makes its +1 declined with no opt-out needed (G3)" do
    anna = person(1)
    plus_one = person(2, 1)

    lookup =
      Effective.index(
        [anna, plus_one],
        [%{person_id: 1, event_id: @party, status: :declined}],
        []
      )

    assert Effective.status(lookup, anna, @party) == :declined
    assert Effective.status(lookup, plus_one, @party) == :declined
    refute Effective.opted_out?(lookup, plus_one, @party)
  end

  test "a non-+1 with no invitation row is not invited" do
    anna = person(1)
    lookup = Effective.index([anna], [], [])

    assert Effective.status(lookup, anna, @dinner) == :not_invited
  end

  test "PER-14: a host not invited makes its +1 not invited, regardless of an opt-out" do
    anna = person(1)
    plus_one = person(2, 1)

    lookup = Effective.index([anna, plus_one], [], [%{person_id: 2, event_id: @dinner}])

    assert Effective.status(lookup, anna, @dinner) == :not_invited
    assert Effective.status(lookup, plus_one, @dinner) == :not_invited
    # PER-14: the +1's data (the opt-out row) is retained even though it has no effect.
    assert Effective.opted_out?(lookup, plus_one, @dinner)
  end

  test "a +1's own status is independent per event" do
    anna = person(1)
    plus_one = person(2, 1)

    lookup =
      Effective.index(
        [anna, plus_one],
        [
          %{person_id: 1, event_id: @dinner, status: :accepted},
          %{person_id: 1, event_id: @party, status: :declined}
        ],
        [%{person_id: 2, event_id: @dinner}]
      )

    assert Effective.status(lookup, plus_one, @dinner) == :declined
    assert Effective.status(lookup, plus_one, @party) == :declined
  end

  test "ids are compared with == and never assumed to be integers (make_ref/0 ids)" do
    dinner_ref = make_ref()
    host_ref = make_ref()
    plus_one_ref = make_ref()

    anna = person(host_ref)
    plus_one = person(plus_one_ref, host_ref)

    lookup =
      Effective.index(
        [anna, plus_one],
        [%{person_id: host_ref, event_id: dinner_ref, status: :accepted}],
        []
      )

    assert Effective.status(lookup, plus_one, dinner_ref) == :accepted
  end
end
