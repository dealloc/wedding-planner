defmodule WeddingPlanner.Transfer.CodecTest do
  @moduledoc """
  `DR-96`'s per-type codec, value by value. Expected JSON values are written literally;
  money is never built from a string (`DR-18`), and a decimal string decodes to exactly
  that decimal under the app's `nl-BE` locale (FP-98e, the codec half).
  """
  use WeddingPlanner.DataCase, async: false

  alias WeddingPlanner.Accounts.Passkey
  alias WeddingPlanner.Events.Event
  alias WeddingPlanner.Invitations.Invitation
  alias WeddingPlanner.Offers.Offer
  alias WeddingPlanner.Offers.OfferLine
  alias WeddingPlanner.Presets.HeadcountPreset
  alias WeddingPlanner.Settings
  alias WeddingPlanner.Transfer.Codec

  defp eur(decimal_string), do: WeddingPlanner.Money.new(Decimal.new(decimal_string))

  describe "encode/3" do
    test "integers, strings, booleans and nil pass through" do
      assert Codec.encode(Event, :id, 12) == 12
      assert Codec.encode(Settings, :id, 1) == 1
      assert Codec.encode(Event, :sort_order, 0) == 0
      assert Codec.encode(Event, :name, "Zoë's brunch") == "Zoë's brunch"
      assert Codec.encode(Offer, :planning_pick, true) == true
      assert Codec.encode(Event, :date, nil) == nil
      assert Codec.encode(OfferLine, :amount, nil) == nil
    end

    test "dates and UTC datetimes are ISO 8601 (NFR-20, NFR-21)" do
      assert Codec.encode(Event, :date, ~D[2026-09-23]) == "2026-09-23"
      assert Codec.encode(Event, :inserted_at, ~U[2026-09-25 12:05:00Z]) == "2026-09-25T12:05:00Z"
    end

    test "enums and enum arrays are their dumped strings; integer arrays stay integers" do
      assert Codec.encode(Invitation, :status, :accepted) == "accepted"

      assert Codec.encode(HeadcountPreset, :certainties, [:certain, :likely]) == [
               "certain",
               "likely"
             ]

      assert Codec.encode(HeadcountPreset, :group_ids, [3, 7]) == [3, 7]
    end

    test "money is a full-precision decimal string plus EUR (NFR-10, NFR-15)" do
      assert Codec.encode(OfferLine, :amount, eur("7641.4999999999999999")) ==
               %{"amount" => "7641.4999999999999999", "currency" => "EUR"}

      assert Codec.encode(Settings, :overall_budget, WeddingPlanner.Money.new(45_000)) ==
               %{"amount" => "45000", "currency" => "EUR"}
    end

    test "an unsupported type raises ArgumentError naming the schema and field" do
      error = assert_raise ArgumentError, fn -> Codec.encode(Passkey, :credential_id, <<1>>) end
      assert error.message =~ "WeddingPlanner.Accounts.Passkey.credential_id"

      assert_raise ArgumentError, fn -> Codec.decode(Passkey, :credential_id, "AQ==") end
      refute Codec.supported?({Passkey, :credential_id})
      assert Codec.supported?({OfferLine, :amount})
    end
  end

  describe "decode/3 accepts exactly what the encoder writes" do
    test "typed values" do
      assert Codec.decode(Event, :sort_order, 12) == {:ok, 12}
      assert Codec.decode(Event, :date, "2026-09-23") == {:ok, ~D[2026-09-23]}

      assert Codec.decode(Event, :inserted_at, "2026-09-25T12:05:00Z") ==
               {:ok, ~U[2026-09-25 12:05:00Z]}

      assert Codec.decode(Invitation, :status, "declined") == {:ok, :declined}

      assert Codec.decode(HeadcountPreset, :want_tiers, ["yes", "obligated"]) ==
               {:ok, [:yes, :obligated]}

      assert Codec.decode(HeadcountPreset, :group_ids, [1, 2]) == {:ok, [1, 2]}
      assert Codec.decode(Offer, :invoicing_complete, false) == {:ok, false}
      assert Codec.decode(OfferLine, :amount, nil) == {:ok, nil}
    end

    test "FP-98e: a decimal string is that exact decimal, never locale-parsed (DR-18)" do
      assert {:ok, %Money{} = precise} =
               Codec.decode(OfferLine, :amount, %{
                 "amount" => "7641.4999999999999999",
                 "currency" => "EUR"
               })

      assert Money.compare(precise, Money.new(:EUR, Decimal.new("7641.4999999999999999"))) == :eq
      assert Decimal.to_string(precise.amount, :normal) == "7641.4999999999999999"

      # Under nl-BE, Money.new(:EUR, "7641.50") would be 764 150.
      assert {:ok, plain} =
               Codec.decode(OfferLine, :amount, %{"amount" => "7641.50", "currency" => "EUR"})

      assert Money.compare(plain, Money.new(:EUR, Decimal.new("7641.50"))) == :eq
    end

    test "the wrong JSON type is refused" do
      assert {:error, "must be a whole number"} = Codec.decode(Event, :sort_order, "12")
      assert {:error, "must be a whole number"} = Codec.decode(Event, :sort_order, 12.0)
      assert {:error, "must be text"} = Codec.decode(Event, :name, 12)
      assert {:error, "must be true or false"} = Codec.decode(Offer, :planning_pick, 1)
      assert {:error, _} = Codec.decode(HeadcountPreset, :group_ids, ["1"])
      assert {:error, _} = Codec.decode(HeadcountPreset, :certainties, "certain")
    end

    test "unknown enum values are refused, never turned into atoms" do
      assert {:error, ~s(has an unknown value "maybe")} =
               Codec.decode(Invitation, :status, "maybe")

      assert {:error, ~s(has an unknown value "sure")} =
               Codec.decode(HeadcountPreset, :certainties, ["certain", "sure"])
    end

    test "non-canonical dates and datetimes are refused" do
      for bad <- ["23/09/2026", "2026-9-23", "2026-09-23T00:00:00Z", ""] do
        assert {:error, _} = Codec.decode(Event, :date, bad), bad
      end

      for bad <- [
            "2026-09-25T14:05:00+02:00",
            "2026-09-25T12:05:00.123456Z",
            "2026-09-25T12:05:00.000Z",
            "2026-09-25 12:05:00Z",
            "2026-09-25T12:05:00"
          ] do
        assert {:error, _} = Codec.decode(Event, :inserted_at, bad), bad
      end
    end

    test "money: bad amounts, other currencies and other shapes are refused" do
      for amount <- ["1,5", "12abc", "", "NaN", "Infinity", "1e3", "+5", ".5", " 5"] do
        assert {:error, _} =
                 Codec.decode(OfferLine, :amount, %{"amount" => amount, "currency" => "EUR"}),
               amount
      end

      assert {:error, message} =
               Codec.decode(OfferLine, :amount, %{"amount" => "5", "currency" => "USD"})

      assert message =~ "USD"

      assert {:error, _} = Codec.decode(OfferLine, :amount, %{"amount" => 5, "currency" => "EUR"})
      assert {:error, _} = Codec.decode(OfferLine, :amount, %{"amount" => "5"})

      assert {:error, _} =
               Codec.decode(OfferLine, :amount, %{"amount" => "5", "currency" => "EUR", "x" => 1})

      assert {:error, _} = Codec.decode(OfferLine, :amount, "5")
    end
  end
end
