defmodule WeddingPlanner.PresetsTest do
  @moduledoc """
  `docs/modules/headcount.md` HC-02, HC-06, HC-07; `docs/04-cross-cutting.md` XC-01,
  XC-02, XC-10 through XC-13; `DR-53`, `DR-54` — the headcount preset CRUD context
  (slice G5).
  """
  use WeddingPlanner.DataCase, async: true

  alias WeddingPlanner.Accounts.Scope
  alias WeddingPlanner.Accounts.User
  alias WeddingPlanner.Guests
  alias WeddingPlanner.Log.Entry
  alias WeddingPlanner.Log.EntityRef
  alias WeddingPlanner.Presets
  alias WeddingPlanner.Realtime

  setup do
    user = insert_user!("Wannes")
    %{user: user, scope: Scope.for_user(user)}
  end

  defp preset_named(name), do: Enum.find(Presets.list_presets(), &(&1.name == name))

  # -- list_presets/0 --------------------------------------------------------------------

  describe "list_presets/0" do
    test "the three HC-06 defaults come back in sort order", %{scope: scope} do
      assert Enum.map(Presets.list_presets(), & &1.name) == ["Minimum", "Likely", "Maximum"]

      {:ok, extra} = Presets.create_preset(scope, %{"name" => "Family only"})

      assert Enum.map(Presets.list_presets(), & &1.name) == [
               "Minimum",
               "Likely",
               "Maximum",
               "Family only"
             ]

      assert List.last(Presets.list_presets()).id == extra.id
    end
  end

  # -- create_preset/2 --------------------------------------------------------------------

  describe "create_preset/2" do
    test "is appended after the current last preset", %{scope: scope} do
      {:ok, first} = Presets.create_preset(scope, %{"name" => "A"})
      {:ok, second} = Presets.create_preset(scope, %{"name" => "B"})
      assert second.sort_order > first.sort_order
    end

    test "requires a name", %{scope: scope} do
      assert {:error, changeset} = Presets.create_preset(scope, %{"name" => ""})
      assert "can't be blank" in errors_on(changeset).name
    end

    test "trims the name", %{scope: scope} do
      assert {:ok, preset} = Presets.create_preset(scope, %{"name" => "  Family only  "})
      assert preset.name == "Family only"
    end

    test "refuses a name over 60 characters", %{scope: scope} do
      assert {:error, changeset} =
               Presets.create_preset(scope, %{"name" => String.duplicate("a", 61)})

      assert "should be at most 60 character(s)" in errors_on(changeset).name
    end

    test "refuses a duplicate name case-insensitively (existing 'Likely')", %{scope: scope} do
      assert {:error, changeset} = Presets.create_preset(scope, %{"name" => "likely"})
      assert "is already used by 'Likely'" in errors_on(changeset).name
    end

    test "refuses an unknown group id", %{scope: scope} do
      assert {:error, changeset} =
               Presets.create_preset(scope, %{"name" => "X", "group_ids" => [999_999]})

      assert "refers to a group that does not exist" in errors_on(changeset).group_ids
    end

    test "allows every criterion empty", %{scope: scope} do
      assert {:ok, preset} = Presets.create_preset(scope, %{"name" => "Anyone"})
      assert preset.invitation_statuses == []
      assert preset.certainties == []
      assert preset.want_tiers == []
      assert preset.age_categories == []
      assert preset.group_ids == []
      assert preset.role == nil
    end

    test "stores criteria de-duplicated, in Valuation.Preset's fixed atom order", %{
      scope: scope
    } do
      assert {:ok, preset} =
               Presets.create_preset(scope, %{
                 "name" => "Custom",
                 "invitation_statuses" => ["accepted", "planned", "accepted", "invited"]
               })

      assert preset.invitation_statuses == [:planned, :invited, :accepted]
    end

    test "stores group_ids de-duplicated, numerically ascending", %{scope: scope} do
      {:ok, a} = Guests.create_group(scope, %{"name" => "A"})
      {:ok, b} = Guests.create_group(scope, %{"name" => "B"})

      assert {:ok, preset} =
               Presets.create_preset(scope, %{
                 "name" => "Custom",
                 "group_ids" => [b.id, a.id, b.id]
               })

      assert preset.group_ids == Enum.sort([a.id, b.id])
    end

    test "logs the create (XC-10)", %{scope: scope, user: user} do
      assert {:ok, preset} = Presets.create_preset(scope, %{"name" => "Family only"})

      entry = Repo.all(Entry) |> Enum.find(&(&1.description =~ "created preset"))
      assert entry.user_id == user.id
      assert entry.entity_type == "headcount_preset"
      assert entry.entity_id == preset.id
      assert entry.description == "Wannes created preset 'Family only'"
    end

    test "broadcasts {:created, preset} (XC-01)", %{scope: scope} do
      Realtime.subscribe(:headcount_preset)
      assert {:ok, preset} = Presets.create_preset(scope, %{"name" => "Family only"})
      assert_received {Realtime, :headcount_preset, {:created, ^preset}}
    end
  end

  # -- update_preset/3 — per-field logging -------------------------------------------------

  describe "update_preset/3 — per-field logging" do
    setup %{scope: scope} do
      {:ok, preset} = Presets.create_preset(scope, %{"name" => "Custom"})
      %{preset: preset}
    end

    test "renaming logs old → new (XC-10)", %{scope: scope, preset: preset} do
      assert {:ok, updated} = Presets.update_preset(scope, preset, %{"name" => "Renamed"})

      entry = Repo.all(Entry) |> Enum.find(&(&1.description =~ "changed the name"))
      assert entry.description == "Wannes changed the name of 'Custom': Custom → Renamed"
      assert entry.entity_id == updated.id
    end

    test "changing a criterion from empty logs 'any' → the human labels", %{
      scope: scope,
      preset: preset
    } do
      assert {:ok, _updated} =
               Presets.update_preset(scope, preset, %{
                 "invitation_statuses" => ["invited", "planned"]
               })

      entry = Repo.all(Entry) |> Enum.find(&(&1.description =~ "invitation statuses"))

      assert entry.description ==
               "Wannes changed the invitation statuses of 'Custom': any → Planned, Invited"
    end

    test "clearing a criterion back to empty logs the labels → 'any'", %{
      scope: scope,
      preset: preset
    } do
      {:ok, preset} =
        Presets.update_preset(scope, preset, %{"age_categories" => ["adult", "child"]})

      Repo.delete_all(Entry)

      assert {:ok, _updated} =
               Presets.update_preset(scope, preset, %{"age_categories" => []})

      entry = Repo.all(Entry) |> Enum.find(&(&1.description =~ "age categories"))

      assert entry.description ==
               "Wannes changed the age categories of 'Custom': Adult, Child → any"
    end

    test "the group criterion logs by group name", %{scope: scope, preset: preset} do
      {:ok, group} = Guests.create_group(scope, %{"name" => "Friends"})

      assert {:ok, _updated} = Presets.update_preset(scope, preset, %{"group_ids" => [group.id]})

      entry = Repo.all(Entry) |> Enum.find(&(&1.description =~ "changed the groups"))
      assert entry.description == "Wannes changed the groups of 'Custom': any → Friends"
    end

    test "a plain role assignment (no other holder) logs old → new, touches nothing else", %{
      scope: scope,
      preset: preset
    } do
      minimum = preset_named("Minimum")
      {:ok, _} = Presets.update_preset(scope, minimum, %{"role" => nil})
      Repo.delete_all(Entry)

      assert {:ok, updated} = Presets.update_preset(scope, preset, %{"role" => "minimum"})
      assert updated.role == :minimum

      entries = Repo.all(Entry)
      assert [entry] = entries
      assert entry.entity_id == preset.id
      assert entry.description == "Wannes changed the role of 'Custom': none → range low end"
    end

    test "unassigning a role logs old → 'none'", %{scope: scope} do
      minimum = preset_named("Minimum")

      assert {:ok, updated} = Presets.update_preset(scope, minimum, %{"role" => nil})
      assert updated.role == nil

      entry = Repo.all(Entry) |> Enum.find(&(&1.description =~ "changed the role"))
      assert entry.description == "Wannes changed the role of 'Minimum': range low end → none"
    end

    test "duplicate name refused case-insensitively", %{scope: scope, preset: preset} do
      assert {:error, changeset} = Presets.update_preset(scope, preset, %{"name" => "LIKELY"})
      assert "is already used by 'Likely'" in errors_on(changeset).name
    end

    test "an unknown group id is refused", %{scope: scope, preset: preset} do
      assert {:error, changeset} =
               Presets.update_preset(scope, preset, %{"group_ids" => [999_999]})

      assert "refers to a group that does not exist" in errors_on(changeset).group_ids
    end

    test "broadcasts {:updated, preset} once", %{scope: scope, preset: preset} do
      Realtime.subscribe(:headcount_preset)
      assert {:ok, updated} = Presets.update_preset(scope, preset, %{"name" => "Renamed"})
      assert_received {Realtime, :headcount_preset, {:updated, ^updated}}
    end
  end

  # -- update_preset/3 — role move ---------------------------------------------------------

  describe "update_preset/3 — role move" do
    test "assigning a role another preset holds moves it: one summary + two children", %{
      scope: scope
    } do
      {:ok, worst_case} = Presets.create_preset(scope, %{"name" => "Worst case"})
      minimum = preset_named("Minimum")

      assert {:ok, updated} = Presets.update_preset(scope, worst_case, %{"role" => "minimum"})
      assert updated.role == :minimum

      reloaded_minimum = Presets.get_preset!(minimum.id)
      assert reloaded_minimum.role == nil

      entries = Repo.all(Entry) |> Enum.reject(&(&1.description =~ "created"))
      {[summary], children} = Enum.split_with(entries, &is_nil(&1.entity_type))

      assert summary.description == "Wannes made 'Worst case' the range low end (was 'Minimum')"
      assert length(children) == 2
      assert Enum.all?(children, &(&1.parent_id == summary.id))
      assert Enum.all?(children, &(&1.description == summary.description))

      assert Enum.sort(Enum.map(children, & &1.entity_id)) ==
               Enum.sort([worst_case.id, minimum.id])
    end

    test "broadcasts {:updated, _} for both the new holder and the cleared one", %{scope: scope} do
      {:ok, worst_case} = Presets.create_preset(scope, %{"name" => "Worst case"})
      minimum = preset_named("Minimum")
      minimum_id = minimum.id

      Realtime.subscribe(:headcount_preset)
      assert {:ok, updated} = Presets.update_preset(scope, worst_case, %{"role" => "minimum"})

      assert_received {Realtime, :headcount_preset, {:updated, ^updated}}
      assert_received {Realtime, :headcount_preset, {:updated, %{id: ^minimum_id, role: nil}}}
    end

    test "never leaves two presets holding the same role (the partial unique index is never violated)",
         %{scope: scope} do
      {:ok, worst_case} = Presets.create_preset(scope, %{"name" => "Worst case"})
      assert {:ok, _updated} = Presets.update_preset(scope, worst_case, %{"role" => "minimum"})

      roles = Presets.list_presets() |> Enum.map(& &1.role) |> Enum.reject(&is_nil/1)
      assert Enum.sort(roles) == Enum.uniq(Enum.sort(roles))
    end
  end

  # -- delete_preset/2 ---------------------------------------------------------------------

  describe "delete_preset/2" do
    test "deletes and logs (XC-10)", %{scope: scope, user: user} do
      {:ok, preset} = Presets.create_preset(scope, %{"name" => "Temp"})
      assert {:ok, deleted} = Presets.delete_preset(scope, preset)

      entry = Repo.all(Entry) |> Enum.find(&(&1.description =~ "deleted preset"))
      assert entry.user_id == user.id
      assert entry.entity_type == "headcount_preset"
      assert entry.entity_id == deleted.id
      assert entry.description == "Wannes deleted preset 'Temp'"
    end

    test "broadcasts {:deleted, id} (XC-01)", %{scope: scope} do
      {:ok, preset} = Presets.create_preset(scope, %{"name" => "Temp"})
      Realtime.subscribe(:headcount_preset)
      assert {:ok, deleted} = Presets.delete_preset(scope, preset)
      id = deleted.id
      assert_received {Realtime, :headcount_preset, {:deleted, ^id}}
    end

    test "a role holder is deletable (HC-06)", %{scope: scope} do
      minimum = preset_named("Minimum")
      assert {:ok, _deleted} = Presets.delete_preset(scope, minimum)
      refute Enum.any?(Presets.list_presets(), &(&1.name == "Minimum"))
    end

    test "the last remaining preset is deletable (HC-06)", %{scope: scope} do
      for preset <- Presets.list_presets(), do: Presets.delete_preset(scope, preset)
      assert Presets.list_presets() == []
    end
  end

  describe "preset_deletion_effects/1" do
    test "a role-less preset has no effects", %{scope: scope} do
      {:ok, preset} = Presets.create_preset(scope, %{"name" => "Roleless"})
      assert Presets.preset_deletion_effects(preset) == []
    end

    test ":likely warns single-figure views default elsewhere" do
      assert Presets.preset_deletion_effects(preset_named("Likely")) == [
               "Single-figure views will default to another preset"
             ]
    end

    test ":minimum warns about the range low end" do
      assert Presets.preset_deletion_effects(preset_named("Minimum")) == [
               "Cost ranges will show a notice until another preset is the range low end"
             ]
    end

    test ":maximum warns about the range high end" do
      assert Presets.preset_deletion_effects(preset_named("Maximum")) == [
               "Cost ranges will show a notice until another preset is the range high end"
             ]
    end
  end

  # -- move_preset/3 ------------------------------------------------------------------------

  describe "move_preset/3" do
    setup %{scope: scope} do
      {:ok, a} = Presets.create_preset(scope, %{"name" => "A"})
      {:ok, b} = Presets.create_preset(scope, %{"name" => "B"})
      %{a: a, b: b}
    end

    test "moving up swaps with the previous preset", %{scope: scope, a: a, b: b} do
      assert :ok = Presets.move_preset(scope, b, :up)
      ids = Presets.list_presets() |> Enum.map(& &1.id)
      assert Enum.find_index(ids, &(&1 == b.id)) < Enum.find_index(ids, &(&1 == a.id))
    end

    test "moving the very first preset up is a no-op", %{scope: scope} do
      minimum = preset_named("Minimum")
      assert :ok = Presets.move_preset(scope, minimum, :up)
      assert Presets.list_presets() |> List.first() |> Map.fetch!(:name) == "Minimum"
    end

    test "logs one summary plus one child per affected preset (XC-12)", %{
      scope: scope,
      a: a,
      b: b
    } do
      :ok = Presets.move_preset(scope, b, :up)

      entries = Repo.all(Entry) |> Enum.reject(&(&1.description =~ "created"))
      {[summary], children} = Enum.split_with(entries, &is_nil(&1.entity_type))

      assert summary.description == "Wannes moved 'B' up in the preset order"
      assert length(children) == 2
      assert Enum.sort(Enum.map(children, & &1.entity_id)) == Enum.sort([a.id, b.id])
    end

    test "broadcasts {:updated, _} for both affected presets", %{scope: scope, a: a, b: b} do
      Realtime.subscribe(:headcount_preset)
      :ok = Presets.move_preset(scope, b, :up)

      assert_received {Realtime, :headcount_preset, {:updated, updated_a}}
      assert_received {Realtime, :headcount_preset, {:updated, updated_b}}
      assert Enum.sort([updated_a.id, updated_b.id]) == Enum.sort([a.id, b.id])
    end
  end

  # -- detach_group/2, presets_naming_group/1 (PER-07, DR-53) ------------------------------

  describe "detach_group/2 and presets_naming_group/1" do
    setup %{scope: scope} do
      {:ok, group} = Guests.create_group(scope, %{"name" => "Friends"})
      {:ok, other_group} = Guests.create_group(scope, %{"name" => "Family"})

      {:ok, alone} =
        Presets.create_preset(scope, %{"name" => "Friends only", "group_ids" => [group.id]})

      {:ok, two_groups} =
        Presets.create_preset(scope, %{
          "name" => "Friends and family",
          "group_ids" => [group.id, other_group.id]
        })

      {:ok, untouched} =
        Presets.create_preset(scope, %{"name" => "Family only", "group_ids" => [other_group.id]})

      %{
        group: group,
        other_group: other_group,
        alone: alone,
        two_groups: two_groups,
        untouched: untouched
      }
    end

    test "presets_naming_group/1 finds only the presets that name it", %{
      group: group,
      alone: alone,
      two_groups: two_groups
    } do
      ids = Presets.presets_naming_group(group) |> Enum.map(& &1.id) |> Enum.sort()
      assert ids == Enum.sort([alone.id, two_groups.id])
    end

    test "rewrites group_ids, logs one child entry per affected preset, leaves others untouched",
         %{
           scope: scope,
           group: group,
           other_group: other_group,
           alone: alone,
           two_groups: two_groups,
           untouched: untouched
         } do
      updated = Presets.detach_group(scope, group)

      by_id = Map.new(updated, &{&1.id, &1})
      assert by_id[alone.id].group_ids == []
      assert by_id[two_groups.id].group_ids == [other_group.id]

      assert Presets.get_preset!(untouched.id).group_ids == [other_group.id]

      descriptions =
        Repo.all(Entry)
        |> Enum.filter(&(&1.entity_type == "headcount_preset"))
        |> Enum.map(& &1.description)

      assert "Wannes removed group 'Friends' from preset 'Friends only' (group deleted)" in descriptions

      assert "Wannes removed group 'Friends' from preset 'Friends and family' (group deleted)" in descriptions
    end
  end

  # -- WeddingPlanner.Log.EntityRef "headcount_preset" resolver ----------------------------

  describe "resolve_log_entity/1" do
    test "resolves an existing preset to /headcount", %{scope: scope} do
      {:ok, preset} = Presets.create_preset(scope, %{"name" => "Custom"})
      assert {:link, "Custom", "/headcount"} = EntityRef.resolve("headcount_preset", preset.id)
    end

    test "a deleted preset degrades to text", %{scope: scope} do
      {:ok, preset} = Presets.create_preset(scope, %{"name" => "Custom"})
      {:ok, _} = Presets.delete_preset(scope, preset)
      assert {:text, _label} = EntityRef.resolve("headcount_preset", preset.id)
    end
  end

  defp insert_user!(display_name) do
    %User{} |> User.changeset(%{display_name: display_name}) |> Repo.insert!()
  end
end
