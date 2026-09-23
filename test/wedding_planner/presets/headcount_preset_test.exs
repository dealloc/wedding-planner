defmodule WeddingPlanner.Presets.HeadcountPresetTest do
  @moduledoc """
  `WeddingPlanner.Presets.HeadcountPreset` — the storage side of `HC-06`'s three
  shipped presets (`DR-47`). The migration seeds the rows with literal SQL, never by
  calling application code, so the cross-check here is what actually proves the literal
  values and `WeddingPlanner.Valuation.Preset.defaults/0` agree: if either ever drifts,
  this test — not a human reading two files side by side — catches it.
  """
  use WeddingPlanner.DataCase, async: true

  alias WeddingPlanner.Presets.HeadcountPreset
  alias WeddingPlanner.Valuation.Preset

  describe "the HC-06 defaults seeded by the migration" do
    test "exactly three rows, in sort order Minimum, Likely, Maximum" do
      rows = Repo.all(HeadcountPreset) |> Enum.sort_by(& &1.sort_order)

      assert Enum.map(rows, & &1.name) == ["Minimum", "Likely", "Maximum"]
      assert Enum.map(rows, & &1.sort_order) == [0, 1, 2]
    end

    test "to_preset/1 of each seeded row equals Preset.defaults/0, element for element (DR-47)" do
      seeded =
        HeadcountPreset
        |> Repo.all()
        |> Enum.sort_by(& &1.sort_order)
        |> Enum.map(&HeadcountPreset.to_preset/1)
        |> Enum.map(&%{&1 | id: nil})

      assert seeded == Preset.defaults()
    end
  end

  describe "to_preset/1" do
    test "converts array columns to MapSets and always yields an empty group_ids" do
      row = %HeadcountPreset{
        id: 42,
        name: "Custom",
        sort_order: 9,
        invitation_statuses: [:invited, :accepted],
        certainties: [:certain],
        want_tiers: [],
        age_categories: [:adult, :child]
      }

      assert HeadcountPreset.to_preset(row) == %Preset{
               id: 42,
               name: "Custom",
               invitation_statuses: MapSet.new([:invited, :accepted]),
               certainties: MapSet.new([:certain]),
               want_tiers: MapSet.new(),
               age_categories: MapSet.new([:adult, :child]),
               group_ids: MapSet.new()
             }
    end
  end

  describe "round trip through the database" do
    test "every array column, including [] and every enum value, survives insert + reload" do
      inserted =
        Repo.insert!(%HeadcountPreset{
          name: "Everything",
          sort_order: 99,
          invitation_statuses: [:planned, :invited, :accepted, :declined],
          certainties: [:certain, :likely, :uncertain],
          want_tiers: [:yes, :maybe, :no, :obligated],
          age_categories: [:adult, :child]
        })

      empty =
        Repo.insert!(%HeadcountPreset{
          name: "Nothing",
          sort_order: 100,
          invitation_statuses: [],
          certainties: [],
          want_tiers: [],
          age_categories: []
        })

      reloaded_full = Repo.get!(HeadcountPreset, inserted.id)
      reloaded_empty = Repo.get!(HeadcountPreset, empty.id)

      assert reloaded_full.invitation_statuses == [:planned, :invited, :accepted, :declined]
      assert reloaded_full.certainties == [:certain, :likely, :uncertain]
      assert reloaded_full.want_tiers == [:yes, :maybe, :no, :obligated]
      assert reloaded_full.age_categories == [:adult, :child]

      assert reloaded_empty.invitation_statuses == []
      assert reloaded_empty.certainties == []
      assert reloaded_empty.want_tiers == []
      assert reloaded_empty.age_categories == []
    end
  end

  # -- database CHECKs and the unique index (raw inserts bypassing any changeset) --------

  describe "database CHECKs (DR-47: json_valid AND json_type = 'array')" do
    defp raw_insert!(fields) do
      now = "2026-01-01T00:00:00Z"

      row =
        Map.merge(
          %{
            sort_order: 0,
            invitation_statuses: "[]",
            certainties: "[]",
            want_tiers: "[]",
            age_categories: "[]",
            inserted_at: now,
            updated_at: now
          },
          Map.new(fields)
        )

      Repo.insert_all("headcount_presets", [row])
    end

    defp assert_check(name, fun) do
      assert_raise Exqlite.Error, ~r/CHECK constraint failed: #{name}(\n|$)/, fun
    end

    test "a valid raw row is accepted (control)" do
      assert {1, _} =
               raw_insert!(
                 name: "Control",
                 invitation_statuses: ~s(["planned"]),
                 certainties: ~s(["certain","likely"])
               )
    end

    test "invitation_statuses must be a JSON array, not a bare JSON string" do
      assert_check("headcount_presets_invitation_statuses_is_json_array", fn ->
        raw_insert!(name: "Bad statuses", invitation_statuses: ~s("x"))
      end)
    end

    test "certainties must be a JSON array" do
      assert_check("headcount_presets_certainties_is_json_array", fn ->
        raw_insert!(name: "Bad certainties", certainties: ~s("x"))
      end)
    end

    test "want_tiers must be a JSON array" do
      assert_check("headcount_presets_want_tiers_is_json_array", fn ->
        raw_insert!(name: "Bad want tiers", want_tiers: ~s("x"))
      end)
    end

    test "age_categories must be a JSON array" do
      assert_check("headcount_presets_age_categories_is_json_array", fn ->
        raw_insert!(name: "Bad age categories", age_categories: ~s("x"))
      end)
    end
  end

  describe "the unique index on name" do
    test "rejects a duplicate name" do
      # `Repo.insert!/1` on a bare struct still recognises the unique index by name and
      # raises `Ecto.ConstraintError` rather than the raw `Exqlite.Error` a query outside
      # Ecto would get — the index is what refuses the row either way.
      assert_raise Ecto.ConstraintError, ~r/headcount_presets_name_index/, fn ->
        Repo.insert!(%HeadcountPreset{name: "Likely", sort_order: 50})
      end
    end
  end
end
