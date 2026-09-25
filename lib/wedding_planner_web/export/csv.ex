defmodule WeddingPlannerWeb.Export.Csv do
  @moduledoc """
  The one CSV encoder every export goes through (`XC-30`, `XC-31`; `DR-86` as amended by
  the orchestrator 2026-09-25).

  `encode/1` is pure: UTF-8 with a leading BOM (`EF BB BF`, spreadsheet compatibility,
  `XC-31`), a header row, then the body rows, **CRLF** after every record including the
  last, fields **semicolon**-separated (the amendment: the user's macOS region is
  `en_BE`, whose Excel/Numbers expect `;` and a decimal comma, not RFC 4180's comma/dot).
  A field is wrapped in `"` iff it contains `;`, `"`, CR or LF, with any inner `"`
  doubled; everything else is written verbatim — no trimming, and deliberately **no
  formula-injection prefixing** (`DR-86` rejected it: both users are the app's own
  authors and the data never leaves their hands, and prefixing would corrupt vendor
  names and negative amounts that start with `-`).

  No CSV library is a dependency (`AGENTS.md`, `DR-86`) — this is the whole encoder.

  ## Cell rendering (`DR-86`)

    * `%Money{}` → `WeddingPlanner.Money.plain/1` — a plain decimal string, comma
      decimal separator, no thousands separator (the amendment).
    * `%Date{}` → `WeddingPlannerWeb.Format.date/1` (`dd/mm/yyyy`, `NFR-23`) — **never**
      call this encoder with a `nil` in place of a date; a caller renders "no date" as
      `nil` (blank) directly, since `Format.date(nil)` returns the "No date yet" text,
      which is `EVT-03`'s wording for a different situation, not a blank export cell.
    * `%Decimal{}` → `Decimal.to_string(d, :normal)` (a percentage, e.g. `"21"`, `"5.5"`).
    * `integer()` → `Integer.to_string/1`.
    * `true` → `"yes"`, `false` → `"no"`.
    * `nil` → `""` (blank).
    * `binary()` → itself, quoted per the rule above.
    * anything else raises `ArgumentError` — a caller bug.

  ## Raises

  `ArgumentError` when a row's length differs from the header row's, or when a row's
  `%Money{}` cells disagree on currency (`NFR-15`) — both are caller bugs, never user
  input.
  """

  # Deliberately does not alias `WeddingPlanner.Money` as `Money` — that would shadow
  # ex_money's own `%Money{}` struct, which is what every cell here actually holds
  # (`WeddingPlannerWeb.BudgetChart`'s moduledoc has the identical precedent).
  alias WeddingPlannerWeb.Export.Table
  alias WeddingPlannerWeb.Format

  @bom <<0xEF, 0xBB, 0xBF>>
  @separator ";"
  @crlf "\r\n"
  @quote_triggers [@separator, "\"", "\r", "\n"]

  @doc "Encodes `table` (see `WeddingPlannerWeb.Export.Table`) — see the moduledoc."
  @spec encode(Table.t()) :: iodata()
  def encode(%{headers: headers, rows: rows}) do
    [
      @bom,
      encode_row(headers),
      Enum.map(rows, &encode_row(check_row!(&1, headers)))
    ]
  end

  defp check_row!(row, headers) do
    if length(row) != length(headers) do
      raise ArgumentError,
            "row has #{length(row)} cell(s), but the header row has #{length(headers)}: " <>
              inspect(row)
    end

    :ok = check_currency!(row)
    row
  end

  defp check_currency!(row) do
    currencies =
      row
      |> Enum.filter(&match?(%Money{}, &1))
      |> Enum.map(& &1.currency)
      |> Enum.uniq()

    case currencies do
      [] -> :ok
      [_one] -> :ok
      many -> raise ArgumentError, "row mixes currencies: #{inspect(many)}"
    end
  end

  defp encode_row(cells) do
    [Enum.map_intersperse(cells, @separator, &encode_cell/1), @crlf]
  end

  defp encode_cell(nil), do: ""
  defp encode_cell(true), do: "yes"
  defp encode_cell(false), do: "no"
  defp encode_cell(%Date{} = date), do: quote_if_needed(Format.date(date))
  defp encode_cell(%Money{} = money), do: quote_if_needed(WeddingPlanner.Money.plain(money))
  defp encode_cell(%Decimal{} = decimal), do: quote_if_needed(Decimal.to_string(decimal, :normal))
  defp encode_cell(cell) when is_integer(cell), do: quote_if_needed(Integer.to_string(cell))
  defp encode_cell(cell) when is_binary(cell), do: quote_if_needed(cell)

  defp encode_cell(other) do
    raise ArgumentError, "cannot render #{inspect(other)} as a CSV cell"
  end

  defp quote_if_needed(value) do
    if String.contains?(value, @quote_triggers) do
      ~s("#{String.replace(value, "\"", "\"\"")}")
    else
      value
    end
  end
end
