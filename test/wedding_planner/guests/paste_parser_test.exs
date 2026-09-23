defmodule WeddingPlanner.Guests.PasteParserTest do
  @moduledoc """
  `WeddingPlanner.Guests.PasteParser`: `DR-26` Q5's paste-a-list splitting rule.
  """
  use ExUnit.Case, async: true

  doctest WeddingPlanner.Guests.PasteParser

  alias WeddingPlanner.Guests.PasteParser

  describe "parse/1 — the Q5 splitting rule" do
    test "a particle-bearing name splits first token / rest, not last token / rest" do
      assert PasteParser.parse("Jan Van Damme") ==
               [{:ok, %{first_name: "Jan", last_name: "Van Damme"}}]
    end

    test "'Last, First' with a comma splits at the first comma" do
      assert PasteParser.parse("Van Damme, Jan") ==
               [{:ok, %{first_name: "Jan", last_name: "Van Damme"}}]
    end

    test "a tab-separated line splits at the tab (spreadsheet columns)" do
      assert PasteParser.parse("Jan\tVan Damme") ==
               [{:ok, %{first_name: "Jan", last_name: "Van Damme"}}]
    end

    test "a single token is a first name only" do
      assert PasteParser.parse("Bo") == [{:ok, %{first_name: "Bo", last_name: nil}}]
    end

    test "a double first name keeps the extra token as part of the last name" do
      assert PasteParser.parse("Anna Marie Peeters") ==
               [{:ok, %{first_name: "Anna", last_name: "Marie Peeters"}}]
    end

    test "a bare comma is an error" do
      assert PasteParser.parse(",") == [{:error, ",", "no name found"}]
    end

    test "blank lines are dropped, not returned as entries" do
      assert PasteParser.parse("Bo\n\n   \nOma") ==
               [
                 {:ok, %{first_name: "Bo", last_name: nil}},
                 {:ok, %{first_name: "Oma", last_name: nil}}
               ]
    end

    test "input order is preserved across a mix of rules and an error" do
      text = "Jan Van Damme\nVan Damme, Jan\n,\nBo"

      assert PasteParser.parse(text) == [
               {:ok, %{first_name: "Jan", last_name: "Van Damme"}},
               {:ok, %{first_name: "Jan", last_name: "Van Damme"}},
               {:error, ",", "no name found"},
               {:ok, %{first_name: "Bo", last_name: nil}}
             ]
    end

    test "internal whitespace collapses to a single space" do
      assert PasteParser.parse("Anna   Marie   Peeters") ==
               [{:ok, %{first_name: "Anna", last_name: "Marie Peeters"}}]
    end
  end
end
