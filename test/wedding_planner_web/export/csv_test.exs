defmodule WeddingPlannerWeb.Export.CsvTest do
  @moduledoc """
  `WeddingPlannerWeb.Export.Csv` (`XC-31`, `DR-86` as amended — `;` separator, money as a
  decimal-comma plain amount). Pure, no database.
  """
  use ExUnit.Case, async: true

  alias WeddingPlanner.Money
  alias WeddingPlannerWeb.Export.Csv

  @bom <<0xEF, 0xBB, 0xBF>>

  # Encodes a one-column, one-row table and strips the BOM, the fixed header line and
  # the trailing record terminator, leaving exactly the one cell's own rendered bytes —
  # safe even when the cell itself contains embedded CR/LF, since a quoted field's last
  # character is always the closing `"`, never bare `\n`.
  defp encode_one_cell(cell) do
    table = %{headers: ["h"], rows: [[cell]]}
    bom_and_header = @bom <> "h\r\n"

    table
    |> Csv.encode()
    |> IO.iodata_to_binary()
    |> String.replace_prefix(bom_and_header, "")
    |> String.replace_suffix("\r\n", "")
  end

  # A tiny, test-only RFC 4180 splitter using `;` in place of `,` — round-trips the
  # encoder's own output back into rows of plain strings, so the encode/decode pair is
  # checked against an oracle independent of `Csv`'s own quoting code.
  defp parse_csv(binary) do
    binary
    |> strip_bom()
    |> do_parse([], [], "", false)
  end

  defp strip_bom(<<0xEF, 0xBB, 0xBF, rest::binary>>), do: rest
  defp strip_bom(other), do: other

  defp do_parse(<<>>, rows, _fields, _field, false) do
    Enum.reverse(rows)
  end

  defp do_parse(<<"\"\"", rest::binary>>, rows, fields, field, true) do
    do_parse(rest, rows, fields, field <> "\"", true)
  end

  defp do_parse(<<"\"", rest::binary>>, rows, fields, field, in_quotes?) do
    do_parse(rest, rows, fields, field, not in_quotes?)
  end

  defp do_parse(<<";", rest::binary>>, rows, fields, field, false) do
    do_parse(rest, rows, [field | fields], "", false)
  end

  defp do_parse(<<"\r\n", rest::binary>>, rows, fields, field, false) do
    row = Enum.reverse([field | fields])
    do_parse(rest, [row | rows], [], "", false)
  end

  defp do_parse(<<c::utf8, rest::binary>>, rows, fields, field, in_quotes?) do
    do_parse(rest, rows, fields, field <> <<c::utf8>>, in_quotes?)
  end

  describe "round-trip (a test-only splitter reads the encoder's own output back)" do
    test "a field containing ;, \" and a newline round-trips exactly" do
      tricky = ~s(Venue; "the good one"\nsee notes)
      plain = "Kasteel Heers"

      table = %{headers: ["Vendor", "Notes"], rows: [[plain, tricky]]}
      bytes = table |> Csv.encode() |> IO.iodata_to_binary()

      assert [["Vendor", "Notes"], [^plain, ^tricky]] = parse_csv(bytes)
    end

    test "a whole table round-trips, header and all cell types as strings" do
      table = %{
        headers: ["Name", "Amount", "Paid"],
        rows: [
          ["Anna; Peeters", Money.new(1_234), true],
          [~s(Tom "Wils"), Money.new(0), false]
        ]
      }

      bytes = table |> Csv.encode() |> IO.iodata_to_binary()

      assert parse_csv(bytes) == [
               ["Name", "Amount", "Paid"],
               ["Anna; Peeters", "1234,00", "yes"],
               [~s(Tom "Wils"), "0,00", "no"]
             ]
    end
  end

  describe "BOM (FP-92a)" do
    test "the first three bytes are the UTF-8 BOM" do
      bytes = %{headers: ["A"], rows: [["x"]]} |> Csv.encode() |> IO.iodata_to_binary()
      assert :binary.part(bytes, 0, 3) == @bom
    end
  end

  describe "records and CRLF" do
    test "a header-only table is the BOM plus one CRLF-terminated line" do
      bytes = %{headers: ["A", "B"], rows: []} |> Csv.encode() |> IO.iodata_to_binary()
      assert bytes == @bom <> "A;B\r\n"
    end

    test "every record ends with CRLF, including the last" do
      bytes = %{headers: ["A"], rows: [["x"], ["y"]]} |> Csv.encode() |> IO.iodata_to_binary()
      assert bytes == @bom <> "A\r\nx\r\ny\r\n"
    end

    test "fields are separated by ;" do
      bytes = %{headers: ["A", "B"], rows: [["x", "y"]]} |> Csv.encode() |> IO.iodata_to_binary()
      assert bytes == @bom <> "A;B\r\nx;y\r\n"
    end
  end

  describe "quoting (FP-92b)" do
    test "a field containing the separator is quoted" do
      assert encode_one_cell("Venue; garden") == ~s("Venue; garden")
    end

    test "a field containing a quote is quoted, with the inner quote doubled" do
      assert encode_one_cell(~s(He said "yes")) == ~s("He said ""yes""")
    end

    test "a field containing a newline is quoted" do
      assert encode_one_cell("line\nbreak") == "\"line\nbreak\""
    end

    test "a field containing a carriage return is quoted" do
      assert encode_one_cell("cr\rhere") == "\"cr\rhere\""
    end

    test "plain text is never quoted" do
      assert encode_one_cell("plain") == "plain"
    end

    test "leading/trailing spaces alone never trigger quoting" do
      assert encode_one_cell(" spaced ") == " spaced "
    end
  end

  describe "cell rendering" do
    test "Money renders through WeddingPlanner.Money.plain/1 (comma decimal)" do
      assert encode_one_cell(Money.new(11_726)) == "11726,00"
    end

    test "Date renders dd/mm/yyyy" do
      assert encode_one_cell(~D[2026-09-21]) == "21/09/2026"
    end

    test "a whole-number Decimal renders via Decimal.to_string/2" do
      assert encode_one_cell(Decimal.new("21")) == "21"
    end

    test "a fractional Decimal renders via Decimal.to_string/2" do
      assert encode_one_cell(Decimal.new("5.5")) == "5.5"
    end

    test "an integer renders via Integer.to_string/1" do
      assert encode_one_cell(42) == "42"
    end

    test "true renders \"yes\"" do
      assert encode_one_cell(true) == "yes"
    end

    test "false renders \"no\"" do
      assert encode_one_cell(false) == "no"
    end

    test "nil renders blank" do
      assert encode_one_cell(nil) == ""
    end

    test "an unknown term raises ArgumentError" do
      assert_raise ArgumentError, fn -> encode_one_cell(%{a: 1}) end
    end
  end

  describe "row shape (caller-bug guards)" do
    test "a row shorter than the header raises" do
      table = %{headers: ["A", "B"], rows: [["x"]]}
      assert_raise ArgumentError, fn -> Csv.encode(table) end
    end

    test "a row longer than the header raises" do
      table = %{headers: ["A"], rows: [["x", "y"]]}
      assert_raise ArgumentError, fn -> Csv.encode(table) end
    end

    test "a row mixing EUR and USD money raises" do
      table = %{headers: ["A", "B"], rows: [[Money.new(1, :EUR), Money.new(1, :USD)]]}
      assert_raise ArgumentError, fn -> Csv.encode(table) end
    end

    test "a row whose money cells share a currency does not raise" do
      table = %{headers: ["A", "B"], rows: [[Money.new(1, :EUR), Money.new(2, :EUR)]]}
      assert %{headers: ["A", "B"]} = table
      assert is_binary(table |> Csv.encode() |> IO.iodata_to_binary())
    end
  end
end
