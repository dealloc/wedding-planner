defmodule WeddingPlanner.Offers.VatRate do
  @moduledoc """
  A VAT rate, stored as an integer in **hundredths of a percent** (`2100` = 21 %, `550` =
  5,5 %) so SQLite never stores a float (`DR-40`, `NFR-12`) — the same "smallest exact
  unit, never a float" stance `WeddingPlanner.Money` takes for amounts, just for a
  percentage instead of a currency.

  No `Ecto`, no `Repo` — a pure module, same shape as `WeddingPlanner.Tasks.Deadline`.

  ## Parsing (`parse/1`, `DR-23`-style, nl-BE)

  Comma is the decimal separator; at most two decimal digits. An optional trailing `%`
  (with or without a preceding space) is stripped before parsing. There is no thousands
  grouping to worry about (a rate is always between 0 and 100), so — unlike
  `WeddingPlanner.Money.parse/2` — a `.` in the input is never a legitimate thousands
  separator; it is always the `DR-18`-style trap of a decimal point typed the English way,
  and is refused with a message pointing at the comma instead.

  ## Examples

      iex> WeddingPlanner.Offers.VatRate.parse("21")
      {:ok, 2100}

      iex> WeddingPlanner.Offers.VatRate.parse("21 %")
      {:ok, 2100}

      iex> WeddingPlanner.Offers.VatRate.parse("21%")
      {:ok, 2100}

      iex> WeddingPlanner.Offers.VatRate.parse("5,5")
      {:ok, 550}

      iex> WeddingPlanner.Offers.VatRate.parse("12,25")
      {:ok, 1225}

      iex> WeddingPlanner.Offers.VatRate.parse("5.5")
      {:error, "Use a comma for the decimal part — for example 5,5, not 5.5."}

      iex> WeddingPlanner.Offers.VatRate.parse("")
      {:error, "Enter a VAT rate."}

  """

  @type bp :: 0..10_000

  @empty_message "Enter a VAT rate."
  @negative_message "A VAT rate cannot be negative."
  @invalid_format_message "Enter a valid rate, e.g. 21 or 5,5."
  @decimal_dot_message "Use a comma for the decimal part — for example 5,5, not 5.5."
  @too_many_decimals_message "Enter at most two decimal digits, e.g. 12,25."
  @multiple_commas_message "Enter only one comma, for the decimal part."
  @missing_decimals_message "Enter the digits after the comma, e.g. 12,25."
  @range_message "Enter a rate between 0 and 100."

  @doc """
  Parses a user-typed nl-BE VAT rate (`"21"`, `"21 %"`, `"21%"`, `"5,5"`, `"12,25"`) into
  basis points (`t:bp/0` — hundredths of a percent, `0..10000`). `"5.5"` (a dot as the
  decimal point) is refused with a message pointing at the comma instead, never silently
  reinterpreted. See the moduledoc for the full accepted/refused table.
  """
  @spec parse(String.t()) :: {:ok, bp()} | {:error, String.t()}
  def parse(input) when is_binary(input) do
    input
    |> String.trim()
    |> strip_percent_suffix()
    |> String.trim()
    |> parse_stripped()
  end

  defp strip_percent_suffix(str) do
    if String.ends_with?(str, "%"), do: String.trim_trailing(str, "%"), else: str
  end

  defp parse_stripped(""), do: {:error, @empty_message}
  defp parse_stripped("-" <> _rest), do: {:error, @negative_message}

  defp parse_stripped(stripped) do
    cond do
      String.contains?(stripped, ".") -> {:error, @decimal_dot_message}
      not Regex.match?(~r/^[0-9,]+$/, stripped) -> {:error, @invalid_format_message}
      true -> parse_number(stripped)
    end
  end

  defp parse_number(stripped) do
    case String.split(stripped, ",") do
      [integer_part] -> finish(integer_part, nil)
      [integer_part, decimal_part] -> finish(integer_part, decimal_part)
      _more_than_one_comma -> {:error, @multiple_commas_message}
    end
  end

  defp finish(integer_part, decimal_part) do
    with :ok <- validate_decimal_part(decimal_part),
         {:ok, integer_value} <- validate_integer_part(integer_part) do
      validate_range(integer_value * 100 + decimal_bp(decimal_part))
    end
  end

  defp validate_decimal_part(nil), do: :ok
  defp validate_decimal_part(""), do: {:error, @missing_decimals_message}

  defp validate_decimal_part(digits) do
    cond do
      not Regex.match?(~r/^\d+$/, digits) -> {:error, @invalid_format_message}
      String.length(digits) > 2 -> {:error, @too_many_decimals_message}
      true -> :ok
    end
  end

  defp validate_integer_part(""), do: {:error, @invalid_format_message}

  defp validate_integer_part(digits) do
    if Regex.match?(~r/^\d+$/, digits) do
      {:ok, String.to_integer(digits)}
    else
      {:error, @invalid_format_message}
    end
  end

  defp decimal_bp(nil), do: 0
  defp decimal_bp(<<digit>>), do: (digit - ?0) * 10
  defp decimal_bp(<<_, _>> = digits), do: String.to_integer(digits)

  defp validate_range(bp) when bp in 0..10_000, do: {:ok, bp}
  defp validate_range(_bp), do: {:error, @range_message}

  @doc """
  Converts basis points to the exact `Decimal` fraction `WeddingPlanner.Money.gross_up/2`
  consumes (`CST-33`) — `Decimal.div/2` by `10_000`, never a float division (`bp / 100`
  would be a `Float` and, worse, off by a factor of 100 — see the fail-proof this
  guards against in `WeddingPlanner.Offers.VatRateTest`).

  ## Examples

      iex> WeddingPlanner.Offers.VatRate.to_decimal(2100)
      Decimal.new("0.21")

      iex> WeddingPlanner.Offers.VatRate.to_decimal(550)
      Decimal.new("0.055")

      iex> WeddingPlanner.Offers.VatRate.to_decimal(0)
      Decimal.new("0")

  """
  @spec to_decimal(bp()) :: Decimal.t()
  def to_decimal(bp) when is_integer(bp) and bp in 0..10_000 do
    Decimal.div(Decimal.new(bp), Decimal.new(10_000))
  end

  @doc """
  Formats basis points for display (activity log wording, the offer form): a whole
  percentage with no decimal part (`2100` -> `"21 %"`), one decimal digit when the
  hundredths digit is zero (`550` -> `"5,5 %"`), otherwise two (`1225` -> `"12,25 %"`).

  ## Examples

      iex> WeddingPlanner.Offers.VatRate.format(2100)
      "21 %"

      iex> WeddingPlanner.Offers.VatRate.format(550)
      "5,5 %"

      iex> WeddingPlanner.Offers.VatRate.format(1225)
      "12,25 %"

      iex> WeddingPlanner.Offers.VatRate.format(0)
      "0 %"

  """
  @spec format(bp()) :: String.t()
  def format(bp) when is_integer(bp) and bp in 0..10_000 do
    whole = div(bp, 100)
    remainder = rem(bp, 100)

    cond do
      remainder == 0 -> "#{whole} %"
      rem(remainder, 10) == 0 -> "#{whole},#{div(remainder, 10)} %"
      true -> "#{whole},#{pad2(remainder)} %"
    end
  end

  defp pad2(n), do: n |> Integer.to_string() |> String.pad_leading(2, "0")
end
