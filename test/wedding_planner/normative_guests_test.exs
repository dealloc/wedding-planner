defmodule WeddingPlanner.NormativeGuestsTest do
  @moduledoc """
  The guest-list fixtures of `docs/07-normative-examples.md` as real rows
  (`WeddingPlanner.NormativeGuests`) and the production path they feed: rows →
  `WeddingPlanner.Valuation.Snapshot.load/1` → `WeddingPlanner.Valuation.Headcount` and
  `WeddingPlanner.Valuation.Offer`, with the **stored** presets from
  `snapshot.headcount_presets` and **no** `headcount:` seam anywhere.

  * `@tag :normative_fixture` — the fixtures' self-checks: rows counted straight from the
    database, without any engine.
  * `@tag :real_path` — H1–H4, the shared fixture against
    `NormativeExamples.shared_headcount/0`, and O1/O2/O4/O5 over real guest and offer
    rows (`HC-02`…`HC-06`, `CST-31`, `CST-36`).

  None carries an `example:` tag: H1–H4 (task 53) and O1–O6 (task 56) are already
  counted on the pure engine tests; these prove the same figures on the real path.
  """
  use WeddingPlanner.DataCase, async: true

  import WeddingPlanner.OfferFixtures, only: [scope_fixture: 0]

  alias WeddingPlanner.Events
  alias WeddingPlanner.Events.Event
  alias WeddingPlanner.Guests
  alias WeddingPlanner.Guests.Person
  alias WeddingPlanner.Invitations
  alias WeddingPlanner.Invitations.Invitation
  alias WeddingPlanner.Invitations.PlusOneOptOut
  alias WeddingPlanner.NormativeExamples
  alias WeddingPlanner.NormativeGuests
  alias WeddingPlanner.NormativeOfferRows, as: Rows
  alias WeddingPlanner.Presets.HeadcountPreset
  alias WeddingPlanner.Valuation.Formula
  alias WeddingPlanner.Valuation.Formula.Step
  alias WeddingPlanner.Valuation.Headcount
  alias WeddingPlanner.Valuation.Offer
  alias WeddingPlanner.Valuation.Preset
  alias WeddingPlanner.Valuation.Snapshot

  @preset_names ~w(Minimum Likely Maximum)

  setup do
    scope = scope_fixture()
    %{scope: scope, dinner: Rows.dinner!(scope)}
  end

  # -- helpers -------------------------------------------------------------------------------

  defp counts(adults, children),
    do: %{adults: adults, children: children, total: adults + children}

  # The stored preset named `name`, from the snapshot — never `Preset.defaults/0`.
  defp stored_preset!(%Snapshot{headcount_presets: presets}, name) do
    case Enum.find(presets, &(&1.name == name)) do
      %Preset{} = preset ->
        preset

      nil ->
        flunk(
          "no stored headcount preset named #{inspect(name)} in the snapshot; " <>
            "stored: #{inspect(Enum.map(presets, & &1.name))}"
        )
    end
  end

  defp loaded_event(%Snapshot{events: events}, %Event{id: id}),
    do: Enum.find(events, &(&1.id == id)) || flunk("event #{inspect(id)} not in the snapshot")

  # Minimum, Likely and Maximum (the stored rows) for `event`, in that order.
  defp by_stored_preset(snapshot, event) do
    event = loaded_event(snapshot, event)
    Enum.map(@preset_names, &Headcount.evaluate(snapshot, stored_preset!(snapshot, &1), event))
  end

  defp loaded_offer(snapshot, %{offer: %{id: id}}), do: Enum.find(snapshot.offers, &(&1.id == id))

  defp assert_money(actual, expected, what) do
    assert Money.equal?(actual, expected),
           "#{what}: expected #{Money.to_string!(expected)}, got #{Money.to_string!(actual)}"
  end

  # {status, certainty, age} => count, over Dinner's invitations and their persons.
  defp dinner_tally(%Event{id: event_id}) do
    from(i in Invitation,
      join: p in Person,
      on: p.id == i.person_id,
      where: i.event_id == ^event_id,
      group_by: [i.status, p.certainty, p.age_category],
      select: {{i.status, p.certainty, p.age_category}, count(i.id)}
    )
    |> Repo.all()
    |> Map.new()
  end

  defp count_rows(queryable), do: Repo.aggregate(queryable, :count)

  # Venue A and Caterer C (NormativeOfferRows) on `dinner` — the event the guests are on.
  defp enter_offers!(scope, dinner) do
    {venue, venue_services} = Rows.category!(scope, NormativeExamples.venue_category())
    {catering, catering_services} = Rows.category!(scope, NormativeExamples.catering_category())

    %{
      venue_a: Rows.offer!(scope, :venue_a, venue, venue_services, dinner),
      caterer_c: Rows.offer!(scope, :caterer_c, catering, catering_services, dinner)
    }
  end

  # -- self-checks: rows straight from the database, no engine ------------------------------

  describe "shared Dinner fixture rows" do
    @tag :normative_fixture
    test "60 + 4 certain and 12 + 2 likely persons, all invited to Dinner — derived from shared_headcount/0",
         %{scope: scope, dinner: dinner} do
      shared = NormativeGuests.shared_dinner!(scope, dinner)

      %{"Minimum" => minimum, "Likely" => likely} = NormativeExamples.shared_headcount()["Dinner"]

      assert dinner_tally(dinner) == %{
               {:invited, :certain, :adult} => minimum.adults,
               {:invited, :certain, :child} => minimum.children,
               {:invited, :likely, :adult} => likely.adults - minimum.adults,
               {:invited, :likely, :child} => likely.children - minimum.children
             }

      assert dinner_tally(dinner) == %{
               {:invited, :certain, :adult} => 60,
               {:invited, :certain, :child} => 4,
               {:invited, :likely, :adult} => 12,
               {:invited, :likely, :child} => 2
             }

      assert count_rows(Person) == 78
      assert count_rows(Invitation) == 78
      assert count_rows(from p in Person, where: not is_nil(p.host_id)) == 0
      assert count_rows(from p in Person, where: p.certainty == :uncertain) == 0
      assert count_rows(PlusOneOptOut) == 0

      assert Enum.map(
               [:certain_adults, :certain_children, :likely_adults, :likely_children, :persons],
               &length(Map.fetch!(shared, &1))
             ) == [60, 4, 12, 2, 78]
    end
  end

  describe "headcount fixture rows" do
    @tag :normative_fixture
    test "H1: 4 accepted (any certainty), 3 invited + certain, 2 invited + likely, 1 planned + uncertain",
         %{scope: scope, dinner: dinner} do
      h1 = NormativeGuests.h1!(scope, dinner)
      tally = dinner_tally(dinner)

      assert tally == %{
               {:accepted, :certain, :adult} => 1,
               {:accepted, :likely, :adult} => 1,
               {:accepted, :uncertain, :adult} => 1,
               {:accepted, :uncertain, :child} => 1,
               {:invited, :certain, :adult} => 3,
               {:invited, :likely, :adult} => 1,
               {:invited, :likely, :child} => 1,
               {:planned, :uncertain, :child} => 1
             }

      # The docs' own four rows, collapsing what they leave open.
      docs_rows =
        Enum.reduce(tally, %{}, fn {{status, certainty, _age}, n}, acc ->
          key = if status == :accepted, do: :accepted, else: {status, certainty}
          Map.update(acc, key, n, &(&1 + n))
        end)

      assert docs_rows == %{
               :accepted => 4,
               {:invited, :certain} => 3,
               {:invited, :likely} => 2,
               {:planned, :uncertain} => 1
             }

      assert count_rows(Person) == 10
      assert count_rows(from p in Person, where: not is_nil(p.host_id)) == 0

      assert Enum.map(
               [:accepted, :invited_certain, :invited_likely, :planned_uncertain, :persons],
               &length(Map.fetch!(h1, &1))
             ) == [4, 3, 2, 1, 10]

      assert %Person{certainty: :uncertain, age_category: :adult} = h1.plus_one_host
      assert h1.plus_one_host in h1.accepted
    end

    for status <- [:confirmed, :possible] do
      @tag :normative_fixture
      test "H2/H3: one unnamed adult #{status} +1 of an accepted person, no opt-out",
           %{scope: scope, dinner: dinner} do
        h1 = NormativeGuests.h1!(scope, dinner)
        plus_one = NormativeGuests.with_plus_one!(scope, h1, unquote(status))
        host_id = h1.plus_one_host.id

        assert [row] = Repo.all(from p in Person, where: not is_nil(p.host_id))
        assert row.id == plus_one.id
        assert row.host_id == host_id
        assert row.plus_one_status == unquote(status)
        assert row.age_category == :adult
        assert {row.first_name, row.last_name} == {nil, nil}

        assert Repo.get_by!(Invitation, person_id: host_id, event_id: dinner.id).status ==
                 :accepted

        assert count_rows(from i in Invitation, where: i.person_id == ^plus_one.id) == 0
        assert count_rows(PlusOneOptOut) == 0
        assert count_rows(Person) == 11
      end
    end

    @tag :normative_fixture
    test "H4: the uninvited person has the given want tier and no invitation at all",
         %{scope: scope} do
      for want_tier <- Person.want_tiers() do
        person = NormativeGuests.uninvited!(scope, want_tier)
        assert Repo.get!(Person, person.id).want_tier == want_tier
        assert count_rows(from i in Invitation, where: i.person_id == ^person.id) == 0
      end
    end
  end

  # -- the real path: rows → Snapshot.load → engines, stored presets, no seam ----------------

  describe "headcount over real rows (H1–H4)" do
    @tag :real_path
    test "H1: Minimum 7, Likely 9, Maximum 10", %{scope: scope, dinner: dinner} do
      NormativeGuests.h1!(scope, dinner)

      assert by_stored_preset(Snapshot.load(Repo), dinner) ==
               [counts(6, 1), counts(7, 2), counts(7, 3)]
    end

    @tag :real_path
    test "H2: a confirmed adult +1 of an accepted person adds 1 to every preset: 8 / 10 / 11",
         %{scope: scope, dinner: dinner} do
      h1 = NormativeGuests.h1!(scope, dinner)
      NormativeGuests.with_plus_one!(scope, h1, :confirmed)

      assert by_stored_preset(Snapshot.load(Repo), dinner) ==
               [counts(7, 1), counts(8, 2), counts(8, 3)]
    end

    @tag :real_path
    test "H3: that +1 possible instead adds 1 to Maximum only: 7 / 9 / 11",
         %{scope: scope, dinner: dinner} do
      h1 = NormativeGuests.h1!(scope, dinner)
      NormativeGuests.with_plus_one!(scope, h1, :possible)

      assert by_stored_preset(Snapshot.load(Repo), dinner) ==
               [counts(6, 1), counts(7, 2), counts(8, 3)]
    end

    for want_tier <- Person.want_tiers() do
      @tag :real_path
      test "H4 (want tier #{want_tier}): no invitation to Dinner counts in no preset for Dinner",
           %{scope: scope, dinner: dinner} do
        NormativeGuests.h1!(scope, dinner)
        person = NormativeGuests.uninvited!(scope, unquote(want_tier))

        # Invited to another event, so "not invited" is shown to be per event — and the
        # person is shown to be a real, countable row.
        {:ok, party} = Events.create_event(scope, %{"name" => "Party"})
        {:ok, _} = Invitations.set_invitation_status(scope, person, party, :accepted)

        snapshot = Snapshot.load(Repo)

        # Dinner is exactly H1: the uninvited person adds nothing to any stored preset…
        assert by_stored_preset(snapshot, dinner) == [counts(6, 1), counts(7, 2), counts(7, 3)]

        # …nor to a preset with every criterion empty (DR-48, INVT-01).
        assert Headcount.evaluate(
                 snapshot,
                 %Preset{name: "Everything"},
                 loaded_event(snapshot, dinner)
               ) ==
                 counts(7, 3)

        # For Party, where they are invited, every stored preset counts them.
        assert by_stored_preset(snapshot, party) == [counts(1, 0), counts(1, 0), counts(1, 0)]
      end
    end
  end

  describe "shared Dinner fixture over real rows" do
    @tag :real_path
    test "stored Likely and Minimum give exactly shared_headcount/0, and agree with fixed_headcount/0",
         %{scope: scope, dinner: dinner} do
      NormativeGuests.shared_dinner!(scope, dinner)
      snapshot = Snapshot.load(Repo)
      event = loaded_event(snapshot, dinner)
      seam = NormativeExamples.fixed_headcount()

      for name <- ["Likely", "Minimum"] do
        preset = stored_preset!(snapshot, name)
        real = Headcount.evaluate(snapshot, preset, event)

        assert real == NormativeExamples.shared_headcount()["Dinner"][name], name
        assert real == seam.(snapshot, preset, event), "#{name}: the seam and the real path"
      end

      assert Headcount.evaluate(snapshot, stored_preset!(snapshot, "Likely"), event) ==
               counts(72, 6)

      assert Headcount.evaluate(snapshot, stored_preset!(snapshot, "Minimum"), event) ==
               counts(60, 4)
    end
  end

  describe "production path: guest rows + offer rows → Snapshot.load → Offer.total/3" do
    @tag :real_path
    test "O1 € 11.726, O2 € 11.478, O4 € 7.641,50, O5 € 7.000,00 — no seam, stored presets",
         %{scope: scope, dinner: dinner} do
      NormativeGuests.shared_dinner!(scope, dinner)
      offers = enter_offers!(scope, dinner)
      snapshot = Snapshot.load(Repo)

      for {id, entered} <- [
            {"O1", offers.venue_a},
            {"O2", offers.venue_a},
            {"O4", offers.caterer_c},
            {"O5", offers.caterer_c}
          ] do
        expected = NormativeExamples.expected(id)
        preset = stored_preset!(snapshot, expected.preset)
        offer = loaded_offer(snapshot, entered)

        assert preset.id != nil, "#{id}: a stored preset has an id"

        %Formula{steps: [first | _], total: {:money, total}} =
          Offer.total(snapshot, offer, preset)

        assert_money(total, expected.total, id)
        assert first == %Step{label: "Headcount preset", value: {:preset, expected.preset}}

        # Every per-person count came from the guest rows: the docs' headcount, per basis.
        headcount = NormativeExamples.shared_headcount()["Dinner"][expected.preset]

        for %{line: line, count: count} <- Offer.breakdown(snapshot, offer, preset).lines,
            line.basis != :flat do
          assert count ==
                   Map.fetch!(
                     headcount,
                     %{per_adult: :adults, per_child: :children, per_attendee: :total}[line.basis]
                   ),
                 "#{id}: line #{inspect(line.id)} (#{line.basis})"
        end
      end
    end

    @tag :real_path
    test "one more certain adult invited to Dinner moves O1 and O2 — the totals read the guest rows",
         %{scope: scope, dinner: dinner} do
      NormativeGuests.shared_dinner!(scope, dinner)
      %{venue_a: venue_a} = enter_offers!(scope, dinner)

      {:ok, extra} =
        Guests.create_person(scope, %{first_name: "Extra", certainty: :certain})

      {:ok, _} = Invitations.set_invitation_status(scope, extra, dinner, :invited)
      snapshot = Snapshot.load(Repo)

      for id <- ["O1", "O2"] do
        expected = NormativeExamples.expected(id)

        %Formula{total: {:money, total}} =
          Offer.total(
            snapshot,
            loaded_offer(snapshot, venue_a),
            stored_preset!(snapshot, expected.preset)
          )

        refute Money.equal?(total, expected.total),
               "#{id} did not move: #{Money.to_string!(total)}"
      end
    end

    @tag :real_path
    test "the stored presets are the ones used: renaming the stored Likely row renames the lookup and the formula step",
         %{scope: scope, dinner: dinner} do
      NormativeGuests.shared_dinner!(scope, dinner)
      %{venue_a: venue_a} = enter_offers!(scope, dinner)

      # No context writes presets before G5; the test renames the stored row directly.
      {1, _} =
        Repo.update_all(from(p in HeadcountPreset, where: p.name == "Likely"),
          set: [name: "Likely*"]
        )

      snapshot = Snapshot.load(Repo)

      assert_raise ExUnit.AssertionError, ~r/no stored headcount preset named "Likely"/, fn ->
        stored_preset!(snapshot, "Likely")
      end

      renamed = stored_preset!(snapshot, "Likely*")

      %Formula{steps: [first | _], total: {:money, total}} =
        Offer.total(snapshot, loaded_offer(snapshot, venue_a), renamed)

      assert first == %Step{label: "Headcount preset", value: {:preset, "Likely*"}}
      assert_money(total, NormativeExamples.expected("O1").total, "O1 under the renamed row")
    end
  end
end
