defmodule WeddingPlanner.Valuation.PresetChoiceTest do
  @moduledoc """
  `WeddingPlanner.Valuation.PresetChoice` (`DR-54`) over plain in-memory
  `WeddingPlanner.Valuation.Preset` lists — no database, no LiveView.
  """
  use ExUnit.Case, async: true

  alias WeddingPlanner.Valuation.Preset
  alias WeddingPlanner.Valuation.PresetChoice

  @minimum %Preset{id: 1, name: "Minimum", role: :minimum}
  @likely %Preset{id: 2, name: "Likely", role: :likely}
  @maximum %Preset{id: 3, name: "Maximum", role: :maximum}

  describe "default/1" do
    test "picks the likely-role preset regardless of name or position" do
      # Renamed away from "Likely" and moved to the front — role, not name or
      # position, decides.
      renamed_and_moved = %{@likely | name: "Expected"}
      presets = [@maximum, renamed_and_moved, @minimum]

      assert PresetChoice.default(presets) == renamed_and_moved
    end

    test "with no likely role, falls back to the first preset" do
      no_role = %{@minimum | role: nil}
      other = %{@maximum | role: nil}

      assert PresetChoice.default([no_role, other]) == no_role
    end

    test "an empty list yields nil" do
      assert PresetChoice.default([]) == nil
    end
  end

  describe "find/2" do
    test "finds the preset whose id matches, string or not" do
      presets = [@minimum, @likely, @maximum]

      assert PresetChoice.find(presets, @minimum.id) == @minimum
      assert PresetChoice.find(presets, to_string(@minimum.id)) == @minimum
    end

    test "a stale id (deleted or never existed) falls back to default/1" do
      presets = [@minimum, @likely, @maximum]

      assert PresetChoice.find(presets, 999) == PresetChoice.default(presets)
    end

    test "nil falls back to default/1" do
      presets = [@minimum, @likely, @maximum]

      assert PresetChoice.find(presets, nil) == PresetChoice.default(presets)
    end
  end

  describe "range_presets/1" do
    test "returns the minimum- and maximum-role presets" do
      presets = [@likely, @maximum, @minimum]

      assert PresetChoice.range_presets(presets) == {:ok, {@minimum, @maximum}}
    end

    test "missing the minimum role" do
      presets = [@likely, @maximum]

      assert PresetChoice.range_presets(presets) == :missing
    end

    test "missing the maximum role" do
      presets = [@likely, @minimum]

      assert PresetChoice.range_presets(presets) == :missing
    end

    test "an empty list is missing" do
      assert PresetChoice.range_presets([]) == :missing
    end
  end

  describe "range/2" do
    test "orders low then high even when the minimum-role preset yields the larger figure" do
      presets = [@minimum, @likely, @maximum]

      # An inverted edit: the "Minimum"-role preset now computes a *larger* figure than
      # the "Maximum"-role one. Fail-proof 2: ordering by role position instead of
      # comparing the actual figures would return {200, 100} here.
      figure_fun = fn
        %Preset{role: :minimum} -> WeddingPlanner.Money.new(200)
        %Preset{role: :maximum} -> WeddingPlanner.Money.new(100)
      end

      assert PresetChoice.range(presets, figure_fun) ==
               {:ok, {WeddingPlanner.Money.new(100), WeddingPlanner.Money.new(200)}}
    end

    test "orders low then high in the ordinary (non-inverted) case" do
      presets = [@minimum, @likely, @maximum]

      figure_fun = fn
        %Preset{role: :minimum} -> WeddingPlanner.Money.new(100)
        %Preset{role: :maximum} -> WeddingPlanner.Money.new(200)
      end

      assert PresetChoice.range(presets, figure_fun) ==
               {:ok, {WeddingPlanner.Money.new(100), WeddingPlanner.Money.new(200)}}
    end

    test "missing either role yields :missing, figure_fun never called" do
      presets = [@likely, @maximum]

      figure_fun = fn _preset ->
        flunk("figure_fun should not be called when a role is missing")
      end

      assert PresetChoice.range(presets, figure_fun) == :missing
    end
  end

  describe "role_presets/1 (DR-71)" do
    test "returns the three role presets by role, whatever their names and order" do
      renamed = %{@likely | name: "Expected"}
      plain = %Preset{id: 4, name: "Friends only", role: nil}
      presets = [plain, @maximum, renamed, @minimum]

      assert PresetChoice.role_presets(presets) ==
               {:ok, %{minimum: @minimum, likely: renamed, maximum: @maximum}}
    end

    test "works on the ad hoc defaults, which carry roles but no ids" do
      [minimum, likely, maximum] = Preset.defaults()

      assert PresetChoice.role_presets(Preset.defaults()) ==
               {:ok, %{minimum: minimum, likely: likely, maximum: maximum}}
    end

    test "missing any one role is :missing" do
      assert PresetChoice.role_presets([@likely, @maximum]) == :missing
      assert PresetChoice.role_presets([@minimum, @maximum]) == :missing
      assert PresetChoice.role_presets([@minimum, @likely]) == :missing
    end

    test "an empty list is missing" do
      assert PresetChoice.role_presets([]) == :missing
    end
  end
end
