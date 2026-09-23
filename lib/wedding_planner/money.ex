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

      iex> WeddingPlanner.Money.new(Decimal.new("7641.50"))
      Money.new(:EUR, "7641.50")

      iex> WeddingPlanner.Money.new(7641)
      Money.new(:EUR, "7641")

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

      iex> WeddingPlanner.Money.sum([WeddingPlanner.Money.new(100), WeddingPlanner.Money.new(50)])
      Money.new(:EUR, "150")

      iex> WeddingPlanner.Money.sum([])
      Money.new(:EUR, "0")

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

      iex> WeddingPlanner.Money.multiply(WeddingPlanner.Money.new(Decimal.new("12.50")), 4)
      Money.new(:EUR, "50.00")

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

      iex> WeddingPlanner.Money.gross_up(WeddingPlanner.Money.new(100), Decimal.new("0.21"))
      Money.new(:EUR, "121.00")

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

      iex> WeddingPlanner.Money.max(WeddingPlanner.Money.new(100), WeddingPlanner.Money.new(150))
      Money.new(:EUR, "150")

  """
  @spec max(Money.t(), Money.t()) :: Money.t()
  def max(%Money{} = a, %Money{} = b) do
    case Money.compare!(a, b) do
      :lt -> b
      _ -> a
    end
  end
end
