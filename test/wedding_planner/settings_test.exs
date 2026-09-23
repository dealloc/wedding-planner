defmodule WeddingPlanner.SettingsTest do
  @moduledoc """
  The Settings singleton (task 21; `docs/03-domain-model.md`'s Settings entity, `BUD-01`,
  `NFR-22`, `XC-10`).
  """
  use WeddingPlanner.DataCase, async: true

  alias WeddingPlanner.Accounts.Scope
  alias WeddingPlanner.Accounts.User
  alias WeddingPlanner.Log.Query
  alias WeddingPlanner.Repo
  alias WeddingPlanner.Settings

  setup do
    wannes = insert_user!("Wannes")
    partner = insert_user!("Partner")

    %{
      wannes: wannes,
      partner: partner,
      scope: Scope.for_user(wannes),
      partner_scope: Scope.for_user(partner)
    }
  end

  describe "get/0 — always returns a struct, never nil" do
    test "creates the row with defaults on first access" do
      assert Repo.aggregate(Settings, :count) == 0

      settings = Settings.get()

      assert %Settings{} = settings
      assert settings.overall_budget == nil
      assert settings.default_time_zone == "Europe/Brussels"
      assert Repo.aggregate(Settings, :count) == 1
    end

    test "a second call returns the same row, not a new one" do
      first = Settings.get()
      second = Settings.get()

      assert first.id == second.id
      assert Repo.aggregate(Settings, :count) == 1
    end
  end

  describe "singleton-ness is enforced in the database, not only by convention" do
    test "a second row with a different id cannot be inserted" do
      _first = Settings.get()

      assert_raise Ecto.ConstraintError, ~r/settings_singleton_id.*check_constraint/s, fn ->
        Repo.insert!(%Settings{id: 2, default_time_zone: "Europe/Brussels"})
      end

      assert Repo.aggregate(Settings, :count) == 1
    end

    test "even the same id cannot be inserted twice (PRIMARY KEY uniqueness)" do
      _first = Settings.get()

      assert_raise Ecto.ConstraintError, ~r/unique_constraint/, fn ->
        Repo.insert!(%Settings{id: 1, default_time_zone: "Europe/Amsterdam"})
      end

      assert Repo.aggregate(Settings, :count) == 1
    end
  end

  describe "overall_budget round-trips as %Money{} EUR (BUD-01, NFR-10)" do
    test "starts unset (nil), never a fake €0,00", %{scope: scope} do
      settings = Settings.get()
      assert Settings.budget_label(settings.overall_budget) == "Not set"
      refute scope == nil
    end

    test "round-trips a set amount through the changeset and the database", %{scope: scope} do
      settings = Settings.get()

      {:ok, updated} = Settings.update(scope, settings, %{"overall_budget_input" => "45.000,50"})

      assert %Money{currency: :EUR} = updated.overall_budget
      assert updated.overall_budget == WeddingPlanner.Money.new(Decimal.new("45000.50"))

      reloaded = Repo.get!(Settings, updated.id)
      assert reloaded.overall_budget == WeddingPlanner.Money.new(Decimal.new("45000.50"))
      assert reloaded.overall_budget.currency == :EUR
    end

    test "clearing the budget (empty input) sets it back to unset", %{scope: scope} do
      settings = Settings.get()
      {:ok, with_budget} = Settings.update(scope, settings, %{"overall_budget_input" => "1000"})
      assert %Money{} = with_budget.overall_budget

      {:ok, cleared} = Settings.update(scope, with_budget, %{"overall_budget_input" => ""})
      assert cleared.overall_budget == nil
    end
  end

  describe "changeset/2 — default_time_zone validated against the real Tz zone list" do
    test "accepts a real IANA zone" do
      changeset = Settings.changeset(Settings.get(), %{"default_time_zone" => "Europe/Amsterdam"})
      assert changeset.valid?
    end

    test "rejects an unknown zone name" do
      changeset =
        Settings.changeset(Settings.get(), %{"default_time_zone" => "Mars/Olympus_Mons"})

      refute changeset.valid?
      assert "is not a recognized time zone" in errors_on(changeset).default_time_zone
    end

    test "rejects nonsense text" do
      changeset = Settings.changeset(Settings.get(), %{"default_time_zone" => "not a zone"})
      refute changeset.valid?
      assert "is not a recognized time zone" in errors_on(changeset).default_time_zone
    end
  end

  describe "changeset/2 — DR-23 the budget field uses WeddingPlanner.Money.parse/1" do
    test "rejects the dot-as-decimal trap with its dedicated message" do
      changeset = Settings.changeset(Settings.get(), %{"overall_budget_input" => "1500.50"})
      refute changeset.valid?

      assert "Use a comma for the decimal part (cents) — for example 45000,50, not 45000.50." in errors_on(
               changeset
             ).overall_budget_input
    end

    test "accepts a valid nl-BE amount" do
      changeset = Settings.changeset(Settings.get(), %{"overall_budget_input" => "45.000,50"})
      assert changeset.valid?

      assert get_field(changeset, :overall_budget) ==
               WeddingPlanner.Money.new(Decimal.new("45000.50"))
    end
  end

  describe "update/3 writes one activity entry per changed field (XC-10)" do
    test "editing only the budget writes exactly one entry", %{scope: scope, wannes: wannes} do
      settings = Settings.get()
      {:ok, updated} = Settings.update(scope, settings, %{"overall_budget_input" => "45.000,00"})

      entries = Query.for_entity(:settings, updated.id)
      assert [entry] = entries
      assert entry.description == "Wannes changed the overall budget: Not set → € 45.000,00"
      assert entry.user_id == wannes.id
    end

    test "editing only the time zone writes exactly one entry", %{scope: scope} do
      settings = Settings.get()

      {:ok, updated} =
        Settings.update(scope, settings, %{"default_time_zone" => "Europe/Amsterdam"})

      entries = Query.for_entity(:settings, updated.id)
      assert [entry] = entries

      assert entry.description ==
               "Wannes changed the default time zone: Europe/Brussels → Europe/Amsterdam"
    end

    test "editing both fields in one submit writes two entries", %{scope: scope} do
      settings = Settings.get()

      {:ok, updated} =
        Settings.update(scope, settings, %{
          "overall_budget_input" => "45.000,00",
          "default_time_zone" => "Europe/Amsterdam"
        })

      entries = Query.for_entity(:settings, updated.id)
      descriptions = Enum.map(entries, & &1.description)

      assert "Wannes changed the overall budget: Not set → € 45.000,00" in descriptions

      assert "Wannes changed the default time zone: Europe/Brussels → Europe/Amsterdam" in descriptions

      assert length(entries) == 2
    end

    test "submitting with no actual change writes no entry", %{scope: scope} do
      settings = Settings.get()

      {:ok, _unchanged} =
        Settings.update(scope, settings, %{"default_time_zone" => settings.default_time_zone})

      assert Query.for_entity(:settings, settings.id) == []
    end

    test "an invalid submission writes no entry and leaves the row untouched", %{scope: scope} do
      settings = Settings.get()

      {:error, changeset} =
        Settings.update(scope, settings, %{"overall_budget_input" => "1500.50"})

      refute changeset.valid?
      assert Query.for_entity(:settings, settings.id) == []
      assert Repo.get!(Settings, settings.id).overall_budget == nil
    end

    test "attributes the entry to the acting user, not hard-coded", %{
      partner_scope: partner_scope,
      partner: partner
    } do
      settings = Settings.get()

      {:ok, updated} =
        Settings.update(partner_scope, settings, %{"overall_budget_input" => "500"})

      [entry] = Query.for_entity(:settings, updated.id)
      assert String.starts_with?(entry.description, "Partner changed")
      assert entry.user_id == partner.id
    end
  end

  describe "broadcast (XC-01)" do
    test "update/3 broadcasts the whole updated struct on the :settings topic", %{scope: scope} do
      WeddingPlanner.Realtime.subscribe(:settings)
      settings = Settings.get()

      {:ok, updated} = Settings.update(scope, settings, %{"overall_budget_input" => "500"})

      assert_receive {WeddingPlanner.Realtime, :settings, {:updated, ^updated}}
    end
  end

  defp insert_user!(display_name) do
    %User{} |> User.changeset(%{display_name: display_name}) |> Repo.insert!()
  end
end
