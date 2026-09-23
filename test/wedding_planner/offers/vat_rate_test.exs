defmodule WeddingPlanner.Offers.VatRateTest do
  @moduledoc """
  `docs/modules/offers-and-comparison.md` `CST-33`, `CST-36`; `DR-40` — the pure VAT-rate
  parser/formatter (offer's default `vat_rate_bp` and slice C3's `vat_rate/1` input).
  """
  use ExUnit.Case, async: true

  doctest WeddingPlanner.Offers.VatRate

  alias WeddingPlanner.Offers.VatRate, as: Subject

  describe "parse/1 — accepted (nl-BE, DR-23-style)" do
    for {input, bp} <- [
          {"21", 2100},
          {"21 %", 2100},
          {"21%", 2100},
          {"5,5", 550},
          {"12,25", 1225},
          {"0", 0},
          {"0,5", 50},
          {"100", 10_000},
          {"100,00", 10_000},
          {"  21  ", 2100},
          {"21  %", 2100}
        ] do
      test "#{inspect(input)} -> #{bp}" do
        assert Subject.parse(unquote(input)) == {:ok, unquote(bp)}
      end
    end
  end

  describe "parse/1 — refused" do
    test "\"5.5\" is refused with the comma message (DR-18-style trap)" do
      assert Subject.parse("5.5") ==
               {:error, "Use a comma for the decimal part — for example 5,5, not 5.5."}
    end

    test "\"21.0\" is refused the same way" do
      assert {:error, message} = Subject.parse("21.0")
      assert message =~ "Use a comma"
    end

    test "empty input" do
      assert Subject.parse("") == {:error, "Enter a VAT rate."}
      assert Subject.parse("   ") == {:error, "Enter a VAT rate."}
    end

    test "negative" do
      assert {:error, message} = Subject.parse("-5")
      assert message =~ "cannot be negative"
    end

    test "more than two decimal digits" do
      assert {:error, message} = Subject.parse("12,255")
      assert message =~ "at most two decimal digits"
    end

    test "more than one comma" do
      assert {:error, message} = Subject.parse("1,2,3")
      assert message =~ "only one comma"
    end

    test "a trailing comma with nothing after it" do
      assert {:error, message} = Subject.parse("21,")
      assert message =~ "digits after the comma"
    end

    test "above 100" do
      assert {:error, message} = Subject.parse("100,5")
      assert message =~ "between 0 and 100"

      assert {:error, message} = Subject.parse("101")
      assert message =~ "between 0 and 100"
    end

    test "not a number at all" do
      assert {:error, _} = Subject.parse("abc")
      assert {:error, _} = Subject.parse("%")
    end
  end

  describe "to_decimal/1 (CST-33 — exact, never a float)" do
    test "2100 bp is exactly 0.21" do
      assert Decimal.equal?(Subject.to_decimal(2100), Decimal.new("0.21"))
    end

    test "550 bp is exactly 0.055" do
      assert Decimal.equal?(Subject.to_decimal(550), Decimal.new("0.055"))
    end

    test "computing bp / 100 instead of bp / 10_000 would be 100x too large — fail-proof (a)" do
      # Pins the exact trap: if to_decimal/1 divided by 100 instead of 10_000, this
      # assertion (the one the task's fail-proof (a) targets) is what would fail.
      refute Decimal.equal?(Decimal.div(Decimal.new(2100), Decimal.new(100)), Decimal.new("0.21"))
      assert Decimal.equal?(Subject.to_decimal(2100), Decimal.new("0.21"))
    end

    test "0 bp is exactly 0" do
      assert Decimal.equal?(Subject.to_decimal(0), Decimal.new("0"))
    end

    test "10_000 bp (100%) is exactly 1" do
      assert Decimal.equal?(Subject.to_decimal(10_000), Decimal.new("1"))
    end
  end

  describe "format/1" do
    test "a whole percentage has no decimal part" do
      assert Subject.format(2100) == "21 %"
      assert Subject.format(0) == "0 %"
      assert Subject.format(10_000) == "100 %"
    end

    test "one decimal digit when the hundredths digit is zero" do
      assert Subject.format(550) == "5,5 %"
    end

    test "two decimal digits otherwise, zero-padded" do
      assert Subject.format(1225) == "12,25 %"
      assert Subject.format(2101) == "21,01 %"
    end
  end
end
