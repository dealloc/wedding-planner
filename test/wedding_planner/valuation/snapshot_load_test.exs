defmodule WeddingPlanner.Valuation.SnapshotLoadTest do
  @moduledoc """
  `WeddingPlanner.Valuation.Snapshot.load/1` and the database side of `apply/2`:
  `NFR-13`, `NFR-33`, `BUD-21`, `EVT-04`, `BUD-01`.

  Queries are counted through the repo's own telemetry event
  (`[:wedding_planner, :repo, :query]`), so an N+1 or a stray write shows up as an extra
  event rather than having to be inferred.
  """
  use WeddingPlanner.DataCase

  alias WeddingPlanner.Accounts.Scope
  alias WeddingPlanner.Accounts.User
  alias WeddingPlanner.Events
  alias WeddingPlanner.Events.Event
  alias WeddingPlanner.Guests
  alias WeddingPlanner.Invitations
  alias WeddingPlanner.Settings
  alias WeddingPlanner.Valuation.Headcount
  alias WeddingPlanner.Valuation.Preset
  alias WeddingPlanner.Valuation.Snapshot

  # Every table `load/1` reads today. A later slice that adds a collection to the loader
  # adds its table here — and nothing else about the budget test below changes.
  @expected_sources [
    "categories",
    "events",
    "groups",
    "headcount_presets",
    "invitations",
    "offer_lines",
    "offers",
    "persons",
    "plus_one_opt_outs",
    "services",
    "settings"
  ]

  # Transaction control around the loader's single read transaction (the sandbox turns
  # it into a savepoint). These carry no `source`.
  @transaction_control ~r/^(begin|commit|rollback|savepoint|release)/i

  @not_built_yet [
    :persons,
    :groups,
    :categories,
    :services,
    :offers,
    :offer_lines,
    :overrides,
    :invoices,
    :invoice_lines
  ]

  def handle_query(_event, _measurements, metadata, test_pid) do
    send(test_pid, {:repo_query, metadata.source, metadata.query})
  end

  defp capture_queries(fun) do
    handler_id = {__MODULE__, make_ref()}

    :ok =
      :telemetry.attach(
        handler_id,
        [:wedding_planner, :repo, :query],
        &__MODULE__.handle_query/4,
        self()
      )

    try do
      result = fun.()
      {result, drain_queries([])}
    after
      :telemetry.detach(handler_id)
    end
  end

  defp drain_queries(acc) do
    receive do
      {:repo_query, source, query} -> drain_queries([{source, query} | acc])
    after
      0 -> Enum.reverse(acc)
    end
  end

  defp insert_event!(name, sort_order) do
    Repo.insert!(%Event{name: name, sort_order: sort_order})
  end

  defp insert_events!(count) do
    for n <- 1..count, do: insert_event!("Event #{n}", n)
  end

  defp insert_user!(display_name) do
    %User{} |> User.changeset(%{display_name: display_name}) |> Repo.insert!()
  end

  describe "load/1 — what it loads" do
    test "events come back in EVT-04 manual sort order, exactly as Events.list_events/0" do
      # Inserted out of order, with a sort_order tie broken by id.
      insert_event!("Party", 2)
      insert_event!("Ceremony", 0)
      insert_event!("Dinner", 1)
      insert_event!("Brunch", 1)

      snapshot = Snapshot.load(Repo)

      assert Enum.map(snapshot.events, & &1.id) == Enum.map(Events.list_events(), & &1.id)
      assert Enum.map(snapshot.events, & &1.name) == ["Ceremony", "Dinner", "Brunch", "Party"]
    end

    test "invitations and plus_one_opt_outs (G3) come back in id order, after real writes" do
      scope = Scope.for_user(insert_user!("Wannes"))
      dinner = insert_event!("Dinner", 0)
      {:ok, anna} = Guests.create_person(scope, %{"first_name" => "Anna"})
      {:ok, tom} = Guests.add_plus_one(scope, anna, %{"first_name" => "Tom"})

      {:ok, invitation} = Invitations.set_invitation_status(scope, anna, dinner, :accepted)
      {:ok, opt_out} = Invitations.set_opt_out(scope, tom, dinner, true)

      snapshot = Snapshot.load(Repo)

      assert Enum.map(snapshot.invitations, & &1.id) == [invitation.id]

      assert [%{person_id: person_id, event_id: event_id, status: :accepted}] =
               snapshot.invitations

      assert person_id == anna.id
      assert event_id == dinner.id

      assert Enum.map(snapshot.plus_one_opt_outs, & &1.id) == [opt_out.id]

      assert [%{person_id: opt_out_person_id, event_id: opt_out_event_id}] =
               snapshot.plus_one_opt_outs

      assert opt_out_person_id == tom.id
      assert opt_out_event_id == dinner.id
    end

    test "carries the stored settings singleton, including the overall budget (BUD-01)" do
      Settings.get()
      |> Settings.changeset(%{"overall_budget_input" => "45.000,50"})
      |> Repo.update!()

      snapshot = Snapshot.load(Repo)

      assert %Settings{id: 1} = snapshot.settings

      assert Money.equal?(
               snapshot.settings.overall_budget,
               WeddingPlanner.Money.new(Decimal.new("45000.50"))
             )
    end

    test "without a settings row, carries an unset budget and does not create the row" do
      snapshot = Snapshot.load(Repo)

      assert %Settings{overall_budget: nil} = snapshot.settings
      assert Repo.aggregate(Settings, :count) == 0
    end

    test "carries every offer line, id order, invalid (event deleted) lines included (DR-41, DR-42)" do
      scope = WeddingPlanner.OfferFixtures.scope_fixture()
      category = WeddingPlanner.OfferFixtures.category_fixture(scope)
      offer = WeddingPlanner.OfferFixtures.offer_fixture(scope, category)
      dinner = insert_event!("Dinner", 0)

      {:ok, per_adult} =
        WeddingPlanner.Offers.create_line(scope, offer, %{
          "label" => "Dinner menu",
          "state" => "mandatory",
          "basis" => "per_adult",
          "event_id" => dinner.id,
          "amount_input" => "85"
        })

      {:ok, flat} =
        WeddingPlanner.Offers.create_line(scope, offer, %{
          "label" => "Cleaning fee",
          "state" => "mandatory",
          "basis" => "flat",
          "amount_input" => "350"
        })

      # XC-41: what event deletion does to the line (inside a Log.action, as documented).
      {:ok, [invalid]} =
        WeddingPlanner.Log.action(scope, "Wannes deleted event 'Dinner'", fn ->
          WeddingPlanner.Offers.detach_event(scope, dinner)
        end)

      snapshot = Snapshot.load(Repo)

      assert Enum.map(snapshot.offer_lines, & &1.id) == [per_adult.id, flat.id]
      assert [%WeddingPlanner.Offers.OfferLine{event_id: nil} = loaded, _] = snapshot.offer_lines
      assert loaded.id == invalid.id
      assert WeddingPlanner.Offers.OfferLine.invalid?(loaded)
      assert Money.equal?(loaded.amount, WeddingPlanner.Money.new(85))
    end

    test "every collection whose entity is not built yet is empty" do
      insert_events!(2)

      snapshot = Snapshot.load(Repo)

      for field <- @not_built_yet, do: assert(Map.fetch!(snapshot, field) == [], "#{field}")
    end
  end

  describe "load/1 — headcount_presets, the HC-06 defaults (G4, DR-47)" do
    test "the three seeded defaults come back as Valuation.Preset, sort_order then id" do
      snapshot = Snapshot.load(Repo)

      assert [minimum, likely, maximum] = snapshot.headcount_presets
      assert Enum.map(snapshot.headcount_presets, & &1.name) == ["Minimum", "Likely", "Maximum"]

      for preset <- [minimum, likely, maximum] do
        assert %Preset{} = preset
        assert is_integer(preset.id)
        assert MapSet.size(preset.group_ids) == 0
      end
    end

    test "the loaded Likely preset is what Headcount.evaluate/3 consumes (HC-06)" do
      scope = Scope.for_user(insert_user!("Wannes"))
      dinner = insert_event!("Dinner", 0)
      {:ok, anna} = Guests.create_person(scope, %{"first_name" => "Anna"})
      {:ok, _invitation} = Invitations.set_invitation_status(scope, anna, dinner, :accepted)

      snapshot = Snapshot.load(Repo)
      likely = Enum.find(snapshot.headcount_presets, &(&1.name == "Likely"))

      assert %{total: 1} = Headcount.evaluate(snapshot, likely, dinner)
    end
  end

  describe "load/1 — bounded queries (NFR-33, NFR-13)" do
    test "reads each table exactly once, and nothing else but transaction control" do
      insert_events!(3)

      {_snapshot, queries} = capture_queries(fn -> Snapshot.load(Repo) end)

      {data_queries, other} = Enum.split_with(queries, fn {source, _} -> source end)

      assert data_queries |> Enum.map(&elem(&1, 0)) |> Enum.sort() == @expected_sources
      assert Enum.all?(other, fn {nil, sql} -> sql =~ @transaction_control end), inspect(other)
      assert Enum.all?(data_queries, fn {_source, sql} -> sql =~ ~r/^SELECT/i end)
    end

    test "the number of queries does not grow with the number of rows (no N+1)" do
      insert_events!(1)
      {_snapshot, with_one} = capture_queries(fn -> Snapshot.load(Repo) end)

      insert_events!(9)
      {snapshot, with_ten} = capture_queries(fn -> Snapshot.load(Repo) end)

      assert length(snapshot.events) == 10
      assert length(with_ten) == length(with_one)
    end
  end

  describe "apply/2 — never touches the database (BUD-21)" do
    test "issues no query at all, and the stored state is unchanged afterwards" do
      [ceremony, dinner] = [insert_event!("Ceremony", 0), insert_event!("Dinner", 1)]
      snapshot = Snapshot.load(Repo)

      changes = [
        {:put, :events, %{ceremony | name: "Civil ceremony"}},
        {:put, :events, %Event{id: make_ref(), name: "Hypothetical brunch", sort_order: 2}},
        {:delete, :events, dinner.id}
      ]

      {changed, queries} = capture_queries(fn -> Snapshot.apply(snapshot, changes) end)

      assert queries == []
      assert Enum.map(changed.events, & &1.name) == ["Civil ceremony", "Hypothetical brunch"]

      assert Enum.map(Events.list_events(), &{&1.id, &1.name}) ==
               [{ceremony.id, "Ceremony"}, {dinner.id, "Dinner"}]
    end

    test "a headcount preset can be what-if'd in place, by id (DR-47)" do
      snapshot = Snapshot.load(Repo)
      likely = Enum.find(snapshot.headcount_presets, &(&1.name == "Likely"))

      changed = Snapshot.apply(snapshot, {:put, :headcount_presets, %{likely | name: "Likely 2"}})

      assert Enum.map(changed.headcount_presets, & &1.name) == ["Minimum", "Likely 2", "Maximum"]
      assert Enum.map(snapshot.headcount_presets, & &1.name) == ["Minimum", "Likely", "Maximum"]
    end
  end
end
