defmodule WeddingPlanner.Offers.OfferLineTest do
  @moduledoc """
  `WeddingPlanner.Offers.OfferLine` — the structural rules of `DR-41` (`CST-20` through
  `CST-23`, `CST-30` through `CST-33`, `XC-41`/`XC-42`) at the changeset, and the named
  database CHECK backing each one: a raw `insert_all` that skips the changeset is still
  refused. Every violating raw row breaks **exactly one** CHECK, and the assertion names
  it, so removing any single CHECK fails its own test.
  """
  use WeddingPlanner.DataCase, async: true

  import WeddingPlanner.OfferFixtures

  alias WeddingPlanner.Categories
  alias WeddingPlanner.Events
  alias WeddingPlanner.Offers.OfferLine

  defp eur(amount), do: WeddingPlanner.Money.new(amount)

  defp changeset(attrs, line \\ %OfferLine{}), do: OfferLine.changeset(line, attrs)

  # A persisted-looking line (id set), for the "touches basis/event" rule.
  defp persisted(fields), do: struct!(OfferLine, Keyword.merge([id: 1, offer_id: 1], fields))

  describe "CST-20: exactly one of service / label" do
    test "a service line or an ad hoc line is accepted" do
      assert changeset(%{"service_id" => 1, "state" => "included"}).valid?

      assert changeset(%{
               "label" => "Base price",
               "state" => "mandatory",
               "basis" => "flat",
               "amount_input" => "4.000"
             }).valid?
    end

    test "neither is refused on service_id" do
      cs = changeset(%{"state" => "mandatory", "basis" => "flat", "amount_input" => "10"})
      refute cs.valid?
      assert errors_on(cs).service_id != []
    end

    test "both is refused on label" do
      cs = changeset(%{"service_id" => 1, "label" => "Extra", "state" => "included"})
      refute cs.valid?
      assert errors_on(cs).label != []
    end

    test "the label is trimmed and a blank label is unset" do
      cs =
        changeset(%{
          "label" => "  Cleaning fee  ",
          "state" => "mandatory",
          "basis" => "flat",
          "amount_input" => "350"
        })

      assert get_field(cs, :label) == "Cleaning fee"

      cs = changeset(%{"service_id" => 1, "label" => "   ", "state" => "included"})
      assert cs.valid?
      assert is_nil(get_field(cs, :label))
    end

    test "a label over 200 characters is refused" do
      cs =
        changeset(%{
          "label" => String.duplicate("a", 201),
          "state" => "mandatory",
          "basis" => "flat",
          "amount_input" => "1"
        })

      assert errors_on(cs).label != []
    end
  end

  describe "CST-22: an ad hoc line is only mandatory or optional" do
    for state <- ~w(included not_offered unknown) do
      test "ad hoc #{state} is refused" do
        cs = changeset(%{"label" => "Extra", "state" => unquote(state)})
        refute cs.valid?
        assert errors_on(cs).state != []
      end
    end

    for state <- ~w(mandatory optional) do
      test "ad hoc #{state} is accepted" do
        assert changeset(%{
                 "label" => "Extra",
                 "state" => unquote(state),
                 "basis" => "flat",
                 "amount_input" => "10"
               }).valid?
      end
    end
  end

  describe "priced states require basis and amount (DR-41)" do
    for state <- ~w(mandatory optional) do
      test "#{state} without a basis is refused" do
        cs = changeset(%{"service_id" => 1, "state" => unquote(state), "amount_input" => "10"})
        assert "can't be blank" in errors_on(cs).basis
      end

      test "#{state} without an amount is refused on amount_input" do
        cs = changeset(%{"service_id" => 1, "state" => unquote(state), "basis" => "flat"})
        assert "can't be blank" in errors_on(cs).amount_input
      end
    end

    test "an unparseable amount is refused with the DR-23 message, never reinterpreted" do
      cs =
        changeset(%{
          "service_id" => 1,
          "state" => "mandatory",
          "basis" => "flat",
          "amount_input" => "1500.50"
        })

      assert errors_on(cs).amount_input == [
               "Use a comma for the decimal part (cents) — for example 45000,50, not 45000.50."
             ]
    end
  end

  describe "unpriced states carry no pricing fields — cleared, not refused (DR-41)" do
    for state <- ~w(included not_offered unknown) do
      test "#{state} submitted with every pricing field stores none of them" do
        cs =
          changeset(%{
            "service_id" => 1,
            "state" => unquote(state),
            "basis" => "per_adult",
            "event_id" => 7,
            "amount_input" => "85",
            "included_quantity" => "10",
            "minimum_charge_input" => "6.800",
            "vat_rate_input" => "12"
          })

        assert cs.valid?

        for field <- [
              :basis,
              :amount,
              :event_id,
              :included_quantity,
              :minimum_charge,
              :vat_rate_bp
            ] do
          assert is_nil(get_field(cs, field)), "#{field} should be cleared"
        end
      end
    end

    test "an unknown line submitted with an amount stores no amount" do
      cs = changeset(%{"service_id" => 1, "state" => "unknown", "amount_input" => "85"})
      assert cs.valid?
      assert is_nil(get_field(cs, :amount))
    end

    test "a garbage amount on an unpriced line is not even parsed" do
      cs = changeset(%{"service_id" => 1, "state" => "included", "amount_input" => "abc"})
      assert cs.valid?
    end

    test "switching a priced line to unpriced clears its stored pricing" do
      line =
        persisted(
          service_id: 1,
          state: :optional,
          basis: :per_adult,
          event_id: 3,
          amount: eur(85),
          minimum_charge: eur(6800),
          included_quantity: 5,
          vat_rate_bp: 1200
        )

      cs = changeset(%{"state" => "not_offered"}, line)
      assert cs.valid?

      assert %{
               basis: nil,
               amount: nil,
               event_id: nil,
               minimum_charge: nil,
               included_quantity: nil,
               vat_rate_bp: nil
             } = cs.changes
    end
  end

  describe "flat basis clears event and included quantity (CST-31, CST-32)" do
    test "a flat line submitted with an event and included quantity stores neither" do
      cs =
        changeset(%{
          "service_id" => 1,
          "state" => "optional",
          "basis" => "flat",
          "event_id" => 7,
          "included_quantity" => "50",
          "amount_input" => "500"
        })

      assert cs.valid?
      assert is_nil(get_field(cs, :event_id))
      assert is_nil(get_field(cs, :included_quantity))
    end

    test "a flat line keeps its minimum charge and line rate" do
      cs =
        changeset(%{
          "label" => "Travel",
          "state" => "mandatory",
          "basis" => "flat",
          "amount_input" => "150",
          "minimum_charge_input" => "200",
          "vat_rate_input" => "21"
        })

      assert cs.valid?
      assert Money.equal?(get_field(cs, :minimum_charge), eur(200))
      assert get_field(cs, :vat_rate_bp) == 2100
    end
  end

  describe "CST-31: a per-person line needs an event" do
    for basis <- ~w(per_adult per_child per_attendee) do
      test "creating a #{basis} line without an event is refused" do
        cs =
          changeset(%{
            "service_id" => 1,
            "state" => "mandatory",
            "basis" => unquote(basis),
            "amount_input" => "10"
          })

        refute cs.valid?
        assert errors_on(cs).event_id != []
      end
    end

    test "an invalid line (event deleted) can have its amount edited and stays invalid" do
      line =
        persisted(service_id: 1, state: :optional, basis: :per_adult, amount: eur(85))

      assert OfferLine.invalid?(line)
      cs = changeset(%{"amount_input" => "90", "event_id" => ""}, line)
      assert cs.valid?
      assert OfferLine.invalid?(apply_changes(cs))
    end

    test "re-submitting an invalid line's basis unchanged does not repair or refuse it" do
      line = persisted(service_id: 1, state: :optional, basis: :per_adult, amount: eur(85))
      cs = changeset(%{"basis" => "per_adult"}, line)
      assert cs.valid?
    end

    test "changing an invalid line's basis to another per-person basis requires an event" do
      line = persisted(service_id: 1, state: :optional, basis: :per_adult, amount: eur(85))
      cs = changeset(%{"basis" => "per_child"}, line)
      assert errors_on(cs).event_id != []
    end

    test "setting an event or switching to flat repairs it" do
      line = persisted(service_id: 1, state: :optional, basis: :per_adult, amount: eur(85))

      refute OfferLine.invalid?(apply_changes(changeset(%{"event_id" => 9}, line)))
      refute OfferLine.invalid?(apply_changes(changeset(%{"basis" => "flat"}, line)))
    end
  end

  describe "included quantity and VAT rate inputs" do
    test "a negative included quantity is refused" do
      cs =
        changeset(%{
          "service_id" => 1,
          "state" => "mandatory",
          "basis" => "per_attendee",
          "event_id" => 1,
          "amount_input" => "12",
          "included_quantity" => "-1"
        })

      assert errors_on(cs).included_quantity != []
    end

    test "vat_rate_input goes through VatRate.parse/1: '12' is 1200, '5.5' is refused" do
      base = %{"label" => "X", "state" => "mandatory", "basis" => "flat", "amount_input" => "1"}
      assert get_field(changeset(Map.put(base, "vat_rate_input", "12")), :vat_rate_bp) == 1200

      cs = changeset(Map.put(base, "vat_rate_input", "5.5"))
      assert errors_on(cs).vat_rate_input != []
    end

    test "blank inputs unset; an omitted key leaves the stored value alone" do
      line =
        persisted(
          label: "Travel",
          state: :mandatory,
          basis: :flat,
          amount: eur(150),
          minimum_charge: eur(200),
          vat_rate_bp: 2100
        )

      cs = changeset(%{"minimum_charge_input" => "", "vat_rate_input" => ""}, line)
      assert is_nil(get_field(cs, :minimum_charge))
      assert is_nil(get_field(cs, :vat_rate_bp))
      assert Money.equal?(get_field(cs, :amount), eur(150))

      cs = changeset(%{"label" => "Travel costs"}, line)
      assert Money.equal?(get_field(cs, :minimum_charge), eur(200))
      assert get_field(cs, :vat_rate_bp) == 2100
    end
  end

  describe "enabled (CST-22)" do
    test "is not castable" do
      cs =
        changeset(%{
          "label" => "Corkage fee",
          "state" => "optional",
          "basis" => "flat",
          "amount_input" => "5",
          "enabled" => "true"
        })

      refute get_field(cs, :enabled)
    end

    test "changing an enabled optional ad hoc line to mandatory resets it" do
      line =
        persisted(label: "Corkage", state: :optional, basis: :flat, amount: eur(5), enabled: true)

      cs = changeset(%{"state" => "mandatory"}, line)
      assert get_change(cs, :enabled) == false
    end

    test "an unrelated edit keeps an enabled optional ad hoc line on" do
      line =
        persisted(label: "Corkage", state: :optional, basis: :flat, amount: eur(5), enabled: true)

      assert get_field(changeset(%{"amount_input" => "6"}, line), :enabled)
    end
  end

  describe "predicates" do
    test "priced_state?/1 and per_person?/1" do
      assert OfferLine.priced_state?(:mandatory)
      assert OfferLine.priced_state?(:optional)
      refute OfferLine.priced_state?(:included)
      refute OfferLine.priced_state?(:not_offered)
      refute OfferLine.priced_state?(:unknown)

      assert OfferLine.per_person?(:per_adult)
      assert OfferLine.per_person?(:per_child)
      assert OfferLine.per_person?(:per_attendee)
      refute OfferLine.per_person?(:flat)
      refute OfferLine.per_person?(nil)
    end

    test "invalid?/1 is per-person with no event, nothing else" do
      assert OfferLine.invalid?(%OfferLine{basis: :per_child, event_id: nil})
      refute OfferLine.invalid?(%OfferLine{basis: :per_child, event_id: 1})
      refute OfferLine.invalid?(%OfferLine{basis: :flat, event_id: nil})
      refute OfferLine.invalid?(%OfferLine{basis: nil, event_id: nil})
    end

    test "vat_rate/1 is the exact Decimal fraction, or nil" do
      assert Decimal.equal?(
               OfferLine.vat_rate(%OfferLine{vat_rate_bp: 1200}),
               Decimal.new("0.12")
             )

      assert is_nil(OfferLine.vat_rate(%OfferLine{vat_rate_bp: nil}))
    end
  end

  # -- database CHECKs --------------------------------------------------------------------

  describe "database CHECKs (raw inserts bypassing the changeset)" do
    setup do
      scope = scope_fixture()
      category = category_fixture(scope)
      offer = offer_fixture(scope, category)
      {:ok, service} = Categories.create_service(scope, category, %{"name" => "Catering"})
      {:ok, event} = Events.create_event(scope, %{"couple_attends" => false, "name" => "Dinner"})
      %{offer: offer, service: service, event: event}
    end

    # A raw row: no schema, no changeset, no Ecto type dumping. The two money columns are
    # the JSON `Money.Ecto.Map.Type` would store (the CHECKs only look at NULL-ness), and
    # `enabled` is the 0/1 integer the schema's boolean is stored as.
    defp raw_insert!(ctx, fields) do
      now = DateTime.utc_now(:second)

      row =
        Map.merge(
          %{offer_id: ctx.offer.id, enabled: 0, inserted_at: now, updated_at: now},
          Map.new(fields)
        )

      Repo.insert_all("offer_lines", [row])
    end

    defp money_json(amount), do: ~s({"amount":"#{amount}","currency":"EUR"})

    defp assert_check(name, fun) do
      assert_raise Exqlite.Error, ~r/CHECK constraint failed: #{name}(\n|$)/, fun
    end

    test "valid raw rows of every shape are accepted (control)", ctx do
      assert {1, _} =
               raw_insert!(ctx,
                 label: "Base price",
                 state: "mandatory",
                 basis: "flat",
                 amount: money_json(4000)
               )

      assert {1, _} =
               raw_insert!(ctx,
                 service_id: ctx.service.id,
                 state: "optional",
                 basis: "per_adult",
                 event_id: ctx.event.id,
                 amount: money_json(85),
                 minimum_charge: money_json(6800),
                 included_quantity: 0,
                 vat_rate_bp: 10_000
               )

      assert {1, _} = raw_insert!(ctx, service_id: ctx.service.id, state: "unknown")

      # XC-41: a per-person line with no event is storable — event deletion needs it.
      assert {1, _} =
               raw_insert!(ctx,
                 service_id: ctx.service.id,
                 state: "optional",
                 basis: "per_adult",
                 amount: money_json(85)
               )

      assert {1, _} =
               raw_insert!(ctx,
                 label: "Corkage",
                 state: "optional",
                 basis: "flat",
                 amount: money_json(5),
                 enabled: 1
               )
    end

    test "CST-20: both a service and a label", ctx do
      assert_check("offer_lines_service_xor_label", fn ->
        raw_insert!(ctx, service_id: ctx.service.id, label: "Extra", state: "included")
      end)
    end

    test "CST-20: neither a service nor a label", ctx do
      assert_check("offer_lines_service_xor_label", fn ->
        raw_insert!(ctx, state: "mandatory", basis: "flat", amount: money_json(1))
      end)
    end

    test "CST-21: an unknown state string", ctx do
      assert_check("offer_lines_state_allowed", fn ->
        raw_insert!(ctx, service_id: ctx.service.id, state: "maybe")
      end)
    end

    test "CST-22: an ad hoc line that is not mandatory/optional", ctx do
      assert_check("offer_lines_state_allowed", fn ->
        raw_insert!(ctx, label: "Extra", state: "included")
      end)
    end

    test "CST-30: an unknown basis string (no per-hour)", ctx do
      assert_check("offer_lines_basis_allowed", fn ->
        raw_insert!(ctx,
          service_id: ctx.service.id,
          state: "mandatory",
          basis: "per_hour",
          amount: money_json(1)
        )
      end)
    end

    test "CST-31: a flat line with an event", ctx do
      assert_check("offer_lines_basis_allowed", fn ->
        raw_insert!(ctx,
          service_id: ctx.service.id,
          state: "mandatory",
          basis: "flat",
          event_id: ctx.event.id,
          amount: money_json(1)
        )
      end)
    end

    test "CST-32: a flat line with an included quantity", ctx do
      assert_check("offer_lines_basis_allowed", fn ->
        raw_insert!(ctx,
          service_id: ctx.service.id,
          state: "mandatory",
          basis: "flat",
          included_quantity: 5,
          amount: money_json(1)
        )
      end)
    end

    test "DR-41: a priced line without a basis", ctx do
      assert_check("offer_lines_priced_state_has_basis_and_amount", fn ->
        raw_insert!(ctx, label: "Extra", state: "mandatory", amount: money_json(1))
      end)
    end

    test "DR-41: a priced line whose amount is the JSON text null (a cleared map column)",
         ctx do
      assert_check("offer_lines_priced_state_has_basis_and_amount", fn ->
        raw_insert!(ctx, label: "Extra", state: "mandatory", basis: "flat", amount: "null")
      end)
    end

    test "DR-41: an unpriced line with cleared money columns (JSON text null) is accepted",
         ctx do
      assert {1, _} =
               raw_insert!(ctx,
                 service_id: ctx.service.id,
                 state: "included",
                 amount: "null",
                 minimum_charge: "null"
               )
    end

    test "DR-41: a priced line without an amount", ctx do
      assert_check("offer_lines_priced_state_has_basis_and_amount", fn ->
        raw_insert!(ctx, label: "Extra", state: "optional", basis: "flat")
      end)
    end

    for {field, value} <- [
          basis: "per_adult",
          amount: :money,
          event_id: :event,
          included_quantity: 3,
          minimum_charge: :money,
          vat_rate_bp: 1200
        ] do
      test "DR-41: an unpriced line carrying #{field}", ctx do
        value =
          case unquote(value) do
            :money -> money_json(10)
            :event -> ctx.event.id
            other -> other
          end

        assert_check("offer_lines_unpriced_state_has_no_pricing", fn ->
          raw_insert!(ctx, [
            {:service_id, ctx.service.id},
            {:state, "included"},
            {unquote(field), value}
          ])
        end)
      end
    end

    test "CST-32: a negative included quantity", ctx do
      assert_check("offer_lines_included_quantity_non_negative", fn ->
        raw_insert!(ctx,
          service_id: ctx.service.id,
          state: "mandatory",
          basis: "per_attendee",
          event_id: ctx.event.id,
          included_quantity: -1,
          amount: money_json(12)
        )
      end)
    end

    for bp <- [-1, 10_001] do
      test "CST-33: a line rate of #{bp} bp", ctx do
        assert_check("offer_lines_vat_rate_bp_range", fn ->
          raw_insert!(ctx,
            label: "Extra",
            state: "mandatory",
            basis: "flat",
            amount: money_json(1),
            vat_rate_bp: unquote(bp)
          )
        end)
      end
    end

    test "CST-22: enabled on a service line", ctx do
      assert_check("offer_lines_enabled_only_optional_ad_hoc", fn ->
        raw_insert!(ctx,
          service_id: ctx.service.id,
          state: "optional",
          basis: "flat",
          amount: money_json(1),
          enabled: 1
        )
      end)
    end

    test "CST-22: enabled that is not a 0/1 boolean", ctx do
      assert_check("offer_lines_enabled_only_optional_ad_hoc", fn ->
        raw_insert!(ctx,
          label: "Corkage",
          state: "optional",
          basis: "flat",
          amount: money_json(5),
          enabled: 2
        )
      end)
    end

    test "CST-22: enabled on a mandatory ad hoc line", ctx do
      assert_check("offer_lines_enabled_only_optional_ad_hoc", fn ->
        raw_insert!(ctx,
          label: "Extra",
          state: "mandatory",
          basis: "flat",
          amount: money_json(1),
          enabled: 1
        )
      end)
    end
  end
end
