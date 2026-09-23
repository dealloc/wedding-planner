defmodule WeddingPlanner.Money do
  @moduledoc """
  The single safe construction site for `%Money{}`, and the arithmetic kernel every
  cost, budget and invoice calculation in this application MUST go through (`NFR-12`).

  ## Why this module exists (DR-18)

  Under the app locale (`nl-BE`, `NFR-11`), `Money.new/2` parses a **string** amount
  using that locale's separators — a comma decimal point and a dot thousands
  separator — not as a literal decimal number:

      Money.new(:EUR, "7641.50")               # => € 764.150,00  — WRONG, 100x too large
      Money.new(:EUR, "7641.50", locale: :en)   # => € 764.150,00  — WRONG, the option is ignored
      Money.new(:EUR, Decimal.new("7641.50"))   # => € 7.641,50    — correct
      Money.new(:EUR, 7641)                     # => € 7.641,00    — correct

  The same trap applies to `inspect/1`: ex_money's own `Inspect` implementation renders a
  `%Money{}` as `Money.new(:EUR, "7641.50")`, which does **not** round-trip under this
  locale — pasting that back into code yields 764150. Logs and ExUnit failure messages
  therefore print a form that is wrong if copied. The examples below deliberately assert
  on `Money.to_string!/1` output rather than the inspected form, so that the doctests
  cannot themselves fall into DR-18.

  This fails silently: no error, no warning, just a wrong number. `new/2` in this
  module therefore only has clauses for `Decimal.t()` and `integer()` amounts. There is
  no clause for a binary, so passing a string amount is a `FunctionClauseError` at the
  call site instead of a silent 100x (or worse) error. See
  `WeddingPlanner.MoneyTest` for the regression test that pins this behaviour so a
  future change of locale cannot silently reintroduce it.

  ## Rounding (`NFR-14`)

  Every function in this module returns an **unrounded** `%Money{}` — full decimal
  precision is preserved all the way through a calculation chain (this is what lets a
  20-significant-digit amount like `7641.4999999999999999` survive a VAT chain
  untruncated, per `CST-36`). Rounding to the currency's minor unit is the **caller's**
  job, done once, at the point a value is either displayed (`Money.round/2` at the
  boundary of the view) or actually billed (invoice lines are entered and stored already
  rounded). Nothing in this module rounds anything.

  ## Aggregation (`NFR-13`)

  Every function here operates on already-loaded `%Money{}` structs in Elixir. Never
  aggregate money in SQL: the stored amount is a string inside a JSON map
  (`Money.Ecto.Map.Type`), and SQL arithmetic on it is unreliable.
  """

  @app_currency :EUR

  @typedoc "An amount safe to construct `Money` from — never a bare string (see DR-18)."
  @type amount :: Decimal.t() | integer()

  @doc """
  Builds a `%Money{}` from a `Decimal` or integer amount, defaulting to the app's single
  currency (`NFR-15`, EUR).

  There is deliberately no clause accepting a binary amount — see the module docs
  (DR-18) for why a string amount under the `nl-BE` locale is silently wrong.

  ## Examples

      iex> WeddingPlanner.Money.new(Decimal.new("7641.50")) |> Money.to_string!()
      "\u20AC\u00A07.641,50"

      iex> WeddingPlanner.Money.new(7641) |> Money.to_string!()
      "\u20AC\u00A07.641,00"

  """
  @spec new(amount(), Money.currency_reference()) :: Money.t()
  def new(amount, currency \\ @app_currency)

  def new(%Decimal{} = amount, currency) do
    Money.new(currency, amount)
  end

  def new(amount, currency) when is_integer(amount) do
    Money.new(currency, amount)
  end

  @doc """
  Sums a list of `Money` amounts, all of which MUST share the same currency.

  Returns zero (in the given currency, defaulting to EUR) for an empty list. Delegates
  to `Money.add!/2` for every step — no raw `Decimal` addition.

  ## Examples

      iex> WeddingPlanner.Money.sum([WeddingPlanner.Money.new(100), WeddingPlanner.Money.new(50)]) |> Money.to_string!()
      "\u20AC\u00A0150,00"

      iex> WeddingPlanner.Money.sum([]) |> Money.to_string!()
      "\u20AC\u00A00,00"

  """
  @spec sum([Money.t()], Money.currency_reference()) :: Money.t()
  def sum(amounts, currency \\ @app_currency)

  def sum([], currency), do: new(0, currency)

  def sum([%Money{currency: currency} | _] = amounts, _currency) do
    Enum.reduce(amounts, new(0, currency), &Money.add!/2)
  end

  @doc """
  Multiplies a `Money` amount by an integer count (e.g. a per-head price by headcount).

  Only an integer multiplier is accepted — never a float (`NFR-12`).

  ## Examples

      iex> WeddingPlanner.Money.multiply(WeddingPlanner.Money.new(Decimal.new("12.50")), 4) |> Money.to_string!()
      "\u20AC\u00A050,00"

  """
  @spec multiply(Money.t(), integer()) :: Money.t()
  def multiply(%Money{} = money, count) when is_integer(count) do
    Money.mult!(money, count)
  end

  @doc """
  Grosses up a VAT-exclusive amount by a VAT rate expressed as a `Decimal` fraction
  (e.g. `Decimal.new("0.21")` for 21%), per CST-33/CST-36: `gross = net * (1 + rate)`.

  The result is unrounded (`NFR-14`); CST-36 requires each line to be grossed up on its
  own rate *before* summing, so rounding here would be premature.

  ## Examples

      iex> WeddingPlanner.Money.gross_up(WeddingPlanner.Money.new(100), Decimal.new("0.21")) |> Money.to_string!()
      "\u20AC\u00A0121,00"

  """
  @spec gross_up(Money.t(), Decimal.t()) :: Money.t()
  def gross_up(%Money{} = net, %Decimal{} = vat_rate) do
    factor = Decimal.add(Decimal.new(1), vat_rate)
    Money.mult!(net, factor)
  end

  @doc """
  Returns the larger of two `Money` amounts of the same currency.

  Used for both CST-32's per-line minimum charge (`max(computed, minimum charge)`) and
  per-offer minimum spend (`max(sum of lines, minimum spend)`).

  ## Examples

      iex> WeddingPlanner.Money.max(WeddingPlanner.Money.new(100), WeddingPlanner.Money.new(150)) |> Money.to_string!()
      "\u20AC\u00A0150,00"

  """
  @spec max(Money.t(), Money.t()) :: Money.t()
  def max(%Money{} = a, %Money{} = b) do
    case Money.compare!(a, b) do
      :lt -> b
      _ -> a
    end
  end

  @invalid_format_message "Enter a valid amount, e.g. 45.000,50."
  @negative_message "Amounts cannot be negative."
  @empty_message "Enter an amount."
  @decimal_dot_message "Use a comma for the decimal part (cents) — for example 45000,50, " <>
                         "not 45000.50."
  @misgrouped_message "Group thousands with dots, in groups of exactly three digits, " <>
                        "e.g. 45.000,50 or 1.234.567,89."
  @too_many_decimals_message "Enter at most two decimal digits, e.g. 45000,50."
  @multiple_commas_message "Enter only one comma, for the decimal part."
  @missing_decimals_message "Enter the digits after the comma, e.g. 45000,50."

  @doc """
  Parses a user-typed nl-BE amount string into a `%Money{}` (`DR-23`), the one parser
  every money **input** field in this application MUST go through — the counterpart to
  `new/2` being the one *construction* site.

  Never builds a `Money` from the raw string itself (that would be exactly the `DR-18`
  trap `new/2`'s missing binary clause exists to prevent) — every accepted form below is
  first turned into a plain, unambiguous decimal string (no thousands separators, `.` as
  the decimal point) and only that is handed to `Decimal.new/1`, then to `new/2`.

  ## The nl-BE rule

  Comma is **the** decimal separator. A dot is *optional* and, when present, MUST group
  digits into groups of exactly three (thousands separators) — `45.000` (=45000),
  `1.234.567,89`. A dot is never treated as a decimal point: `1500.50` and `1500.5` are
  refused outright, with a message telling the user to use a comma instead, rather than
  silently reinterpreted (the same "never reinterpret, never guess" stance `new/2`'s
  moduledoc takes towards `DR-18`).

  Surrounding whitespace and an optional leading `€` or `€ ` are stripped before
  parsing. Negative amounts are refused for now (unspecified by the business rules; a
  budget cannot be negative — later money fields may need a different rule, flagged
  rather than decided here).

  ## Accepted forms

      45000            -> € 45.000,00
      45.000           -> € 45.000,00
      45000,50         -> € 45.000,50
      45.000,50        -> € 45.000,50
      45.000,5         -> € 45.000,50   (one decimal digit is padded by Money itself)
      1.234.567,89     -> € 1.234.567,89
      "  45.000,50  "  -> € 45.000,50   (surrounding whitespace)
      "€ 45.000,50"    -> € 45.000,50   (leading € with a space)
      "€45.000,50"     -> € 45.000,50   (leading € with no space)

  ## Refused forms

      1500.50          -> a dot followed by two digits looks like a decimal point (use a comma)
      1500.5           -> same trap, one digit
      45.00.000        -> misgrouped: the middle group is 2 digits, not 3
      4.5000           -> misgrouped: the group after the dot is 4 digits, not 3
      45000,123        -> more than two decimal digits
      45,000,50        -> more than one comma
      -45000           -> negative
      ""               -> empty
      "forty five"     -> not a number at all

  ## Examples

      iex> {:ok, money} = WeddingPlanner.Money.parse("45.000,50")
      iex> Money.to_string!(money)
      "€ 45.000,50"

      iex> {:ok, money} = WeddingPlanner.Money.parse("45000")
      iex> Money.to_string!(money)
      "€ 45.000,00"

      iex> {:ok, money} = WeddingPlanner.Money.parse("1.234.567,89")
      iex> Money.to_string!(money)
      "€ 1.234.567,89"

      iex> WeddingPlanner.Money.parse("1500.50")
      {:error, "Use a comma for the decimal part (cents) — for example 45000,50, not 45000.50."}

      iex> WeddingPlanner.Money.parse("-45000")
      {:error, "Amounts cannot be negative."}

      iex> WeddingPlanner.Money.parse("")
      {:error, "Enter an amount."}

  """
  @spec parse(String.t(), Money.currency_reference()) :: {:ok, Money.t()} | {:error, String.t()}
  def parse(input, currency \\ @app_currency)

  def parse(input, currency) when is_binary(input) do
    input
    |> String.trim()
    |> strip_currency_prefix()
    |> String.trim()
    |> parse_stripped(currency)
  end

  defp strip_currency_prefix("€" <> rest), do: rest
  defp strip_currency_prefix(other), do: other

  defp parse_stripped("-" <> _rest, _currency), do: {:error, @negative_message}
  defp parse_stripped("", _currency), do: {:error, @empty_message}

  defp parse_stripped(stripped, currency) do
    if Regex.match?(~r/^[0-9.,]+$/, stripped) do
      parse_number(stripped, currency)
    else
      {:error, @invalid_format_message}
    end
  end

  defp parse_number(stripped, currency) do
    case String.split(stripped, ",") do
      [integer_part] ->
        finish(integer_part, nil, currency)

      [integer_part, decimal_part] ->
        finish(integer_part, decimal_part, currency)

      _more_than_one_comma ->
        {:error, @multiple_commas_message}
    end
  end

  defp finish(integer_part, decimal_part, currency) do
    with :ok <- validate_decimal_part(decimal_part),
         {:ok, integer_digits} <- validate_integer_part(integer_part, decimal_part) do
      amount_string =
        case decimal_part do
          nil -> integer_digits
          digits -> integer_digits <> "." <> digits
        end

      {:ok, new(Decimal.new(amount_string), currency)}
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

  defp validate_integer_part("", _decimal_part), do: {:error, @invalid_format_message}

  defp validate_integer_part(integer_part, decimal_part) do
    case String.split(integer_part, ".") do
      [single] ->
        if Regex.match?(~r/^\d+$/, single) do
          {:ok, single}
        else
          {:error, @invalid_format_message}
        end

      [first | rest] ->
        validate_grouped(first, rest, decimal_part)
    end
  end

  # A single dot whose final group is one or two digits, with no comma anywhere in the
  # input, is the `DR-18`-style trap: the user almost certainly meant `.` as a decimal
  # point (`1500.50`, `1500.5`). Refused with a distinct message rather than either
  # silently reinterpreted or folded into the generic misgrouping error.
  defp validate_grouped(first, rest, decimal_part) do
    last = List.last(rest)

    if is_nil(decimal_part) and Regex.match?(~r/^\d{1,2}$/, last) do
      {:error, @decimal_dot_message}
    else
      if valid_grouping?(first, rest) do
        {:ok, Enum.join([first | rest])}
      else
        {:error, @misgrouped_message}
      end
    end
  end

  defp valid_grouping?(first, rest) do
    Regex.match?(~r/^\d{1,3}$/, first) and Enum.all?(rest, &Regex.match?(~r/^\d{3}$/, &1))
  end
end
