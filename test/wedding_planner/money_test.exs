defmodule WeddingPlanner.MoneyTest do
  use WeddingPlanner.DataCase, async: true

  alias WeddingPlanner.Money, as: Subject
  alias WeddingPlanner.MoneyProbe
  alias WeddingPlanner.Repo

  describe "new/2 — DR-18 regression: locale-string construction is unsafe and unsupported" do
    test "raw Money.new/2 silently mis-parses a decimal string under the nl-BE locale" do
      # This pins the exact failure mode DR-18 describes: under nl-BE, a string amount
      # is parsed using nl-BE's own number format (dot = thousands, comma = decimal),
      # not as the literal decimal it looks like. 7641.50 becomes 764150.00 — 100x too
      # large — with no error and no warning. If a future change to the app locale
      # makes this test fail, that is the point: it means the silent trap has moved or
      # closed, and this suite (and WeddingPlanner.Money) need to be revisited.
      wrong = Money.new(:EUR, "7641.50")
      assert Money.to_string!(wrong) == "€ 764.150,00"
      refute Money.to_string!(wrong) == "€ 7.641,50"

      # Passing `locale: :en` does not help — the option is ignored for this parse.
      still_wrong = Money.new(:EUR, "7641.50", locale: :en)
      assert Money.to_string!(still_wrong) == "€ 764.150,00"
    end

    test "WeddingPlanner.Money.new/2 has no clause for a binary amount" do
      # Dispatched dynamically (via `apply/3`) so this is a genuine runtime check of the
      # missing clause, not something the type checker could instead flag at compile time.
      assert_raise FunctionClauseError, fn ->
        apply(Subject, :new, ["7641.50"])
      end
    end

    test "WeddingPlanner.Money.new/2 with a Decimal amount is correct and renders in nl-BE form" do
      money = Subject.new(Decimal.new("7641.50"))
      assert Money.to_string!(money) == "€ 7.641,50"
    end

    test "WeddingPlanner.Money.new/2 with an integer amount is correct and renders in nl-BE form" do
      money = Subject.new(7641)
      assert Money.to_string!(money) == "€ 7.641,00"
    end

    test "defaults to the app's single currency, EUR (NFR-15)" do
      assert %Money{currency: :EUR} = Subject.new(1)
    end

    test "accepts an explicit currency (the currency is still stored per amount, NFR-15)" do
      assert %Money{currency: :USD} = Subject.new(1, :USD)
    end
  end

  describe "sum/1" do
    test "sums a list of amounts via Money.add!, not raw Decimal arithmetic" do
      amounts = [
        Subject.new(Decimal.new("10.10")),
        Subject.new(20),
        Subject.new(Decimal.new("0.05"))
      ]

      assert Subject.sum(amounts) == Subject.new(Decimal.new("30.15"))
    end

    test "returns zero EUR for an empty list" do
      assert Subject.sum([]) == Subject.new(0)
    end
  end

  describe "multiply/2" do
    test "multiplies by an integer count" do
      assert Subject.multiply(Subject.new(Decimal.new("12.50")), 4) ==
               Subject.new(Decimal.new("50.00"))
    end
  end

  describe "gross_up/2 — CST-33/CST-36 VAT gross-up" do
    test "applies gross = net * (1 + rate)" do
      net = Subject.new(100)
      assert Subject.gross_up(net, Decimal.new("0.21")) == Subject.new(Decimal.new("121.00"))
    end

    test "keeps full, unrounded precision through the chain (NFR-14, CST-36)" do
      net = Subject.new(Decimal.new("7641.4999999999999999"))
      grossed = Subject.gross_up(net, Decimal.new("0.21"))

      # Unrounded: 7641.4999999999999999 * 1.21 = 9246.214999999999999879, kept in full.
      refute Money.round(grossed).amount == grossed.amount
      assert Decimal.compare(grossed.amount, Decimal.new("9246.214999999999999879")) == :eq
    end
  end

  describe "max/2 — CST-32 minimum charge / minimum spend" do
    test "returns the larger of two amounts" do
      assert Subject.max(Subject.new(100), Subject.new(150)) == Subject.new(150)
      assert Subject.max(Subject.new(150), Subject.new(100)) == Subject.new(150)
    end

    test "either operand may be returned when they are equal" do
      assert Subject.max(Subject.new(100), Subject.new(100)) == Subject.new(100)
    end
  end

  describe "Money.Ecto.Map.Type persistence (NFR-10)" do
    test "round-trips a EUR amount through a real migration and schema" do
      {:ok, probe} =
        %MoneyProbe{}
        |> Ecto.Changeset.change(price: Subject.new(Decimal.new("42.50")), deposit: nil)
        |> Repo.insert()

      reloaded = Repo.get!(MoneyProbe, probe.id)

      assert reloaded.price == Subject.new(Decimal.new("42.50"))
      assert reloaded.price.currency == :EUR
    end

    test "a 20-significant-digit amount survives storage untruncated (CST-36 depends on it)" do
      high_precision = Decimal.new("7641.4999999999999999")
      # 4 digits before the point + 16 after == 20 significant digits.
      assert String.length(Decimal.to_string(high_precision)) ==
               String.length("7641.4999999999999999")

      {:ok, probe} =
        %MoneyProbe{}
        |> Ecto.Changeset.change(price: Subject.new(high_precision))
        |> Repo.insert()

      reloaded = Repo.get!(MoneyProbe, probe.id)

      assert Decimal.compare(reloaded.price.amount, high_precision) == :eq
      assert Decimal.to_string(reloaded.price.amount) == Decimal.to_string(high_precision)
    end

    test "a nil money column round-trips as nil" do
      {:ok, probe} =
        %MoneyProbe{}
        |> Ecto.Changeset.change(price: Subject.new(1), deposit: nil)
        |> Repo.insert()

      reloaded = Repo.get!(MoneyProbe, probe.id)

      assert is_nil(reloaded.deposit)
      assert reloaded.price == Subject.new(1)
    end

    test "two independent money columns on one row round-trip independently" do
      {:ok, probe} =
        %MoneyProbe{}
        |> Ecto.Changeset.change(
          price: Subject.new(Decimal.new("199.99")),
          deposit: Subject.new(Decimal.new("50.00"))
        )
        |> Repo.insert()

      reloaded = Repo.get!(MoneyProbe, probe.id)

      assert reloaded.price == Subject.new(Decimal.new("199.99"))
      assert reloaded.deposit == Subject.new(Decimal.new("50.00"))
      refute reloaded.price == reloaded.deposit
    end
  end
end
