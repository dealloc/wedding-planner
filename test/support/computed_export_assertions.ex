defmodule WeddingPlannerWeb.ComputedExportAssertions do
  @moduledoc """
  Test support for the computed CSV exporters (`WeddingPlannerWeb.Export.Headcount`,
  `.Offers`, `.Budget`, task 93, `DR-86`, `DR-89`): the table-shape checks every one of
  their tests applies, plus small lookups for readable assertions.

  `assert_table_shape/1` checks the exporter contract (`w14-plan.md` §5): a string stem,
  a non-empty list of string headers, every row as long as the headers, at most one
  `"Currency"` column and, if present, last — its cell the row's currency code
  (`"EUR"`) exactly when the row holds a `%Money{}`, else `nil` — and no cell outside
  the contract's cell type (never a float, an atom or a map other than `%Money{}`,
  `%Decimal{}` or `%Date{}`).
  """

  import ExUnit.Assertions

  @doc "Asserts the exporter contract's shape for `table` (see the moduledoc) and returns it."
  def assert_table_shape(%{stem: stem, headers: headers, rows: rows} = table) do
    assert is_binary(stem) and stem != ""
    assert [_ | _] = headers
    assert Enum.all?(headers, &is_binary/1)

    width = length(headers)
    currency_columns = Enum.count(headers, &(&1 == "Currency"))
    assert currency_columns in [0, 1], "at most one Currency column, got #{currency_columns}"

    if currency_columns == 1 do
      assert List.last(headers) == "Currency", "Currency must be the last column"
    end

    for row <- rows do
      assert length(row) == width,
             "row #{inspect(row)} has #{length(row)} cells, headers have #{width}"

      for cell <- row do
        assert cell?(cell), "not an export cell: #{inspect(cell)}"
      end

      if currency_columns == 1 do
        {amounts, [code]} = Enum.split(row, width - 1)

        expected =
          Enum.find_value(amounts, fn
            %Money{currency: currency} -> Atom.to_string(currency)
            _other -> nil
          end)

        assert code == expected, "Currency cell #{inspect(code)} for row #{inspect(row)}"
      end
    end

    table
  end

  @doc "The cell of `row` under `header` in `table`."
  def cell(%{headers: headers}, row, header) do
    index = Enum.find_index(headers, &(&1 == header)) || flunk("no column #{inspect(header)}")
    Enum.at(row, index)
  end

  @doc "The rows of `table` whose cell under `header` equals `value`."
  def rows_where(table, header, value),
    do: Enum.filter(table.rows, &(cell(table, &1, header) == value))

  @doc "The single row of `table` whose cell under `header` equals `value`."
  def row_where!(table, header, value) do
    case rows_where(table, header, value) do
      [row] -> row
      other -> flunk("expected one row with #{header} = #{inspect(value)}, got #{inspect(other)}")
    end
  end

  @doc "Asserts that `actual` is a `%Money{}` equal to `expected` (a `%Money{}`)."
  def assert_money(actual, %Money{} = expected, what \\ "amount") do
    assert %Money{} = actual, "#{what}: expected #{inspect(expected)}, got #{inspect(actual)}"

    assert Money.equal?(actual, expected),
           "#{what}: expected #{Money.to_string!(expected)}, got #{Money.to_string!(actual)}"
  end

  @doc "EUR from integer cents — test oracles only (never production arithmetic)."
  def cents(cents) when is_integer(cents),
    do: WeddingPlanner.Money.new(Decimal.div(Decimal.new(cents), 100))

  defp cell?(nil), do: true
  defp cell?(value) when is_binary(value) or is_integer(value) or is_boolean(value), do: true
  defp cell?(%Money{amount: %Decimal{}}), do: true
  defp cell?(%Decimal{}), do: true
  defp cell?(%Date{}), do: true
  defp cell?(_other), do: false
end
