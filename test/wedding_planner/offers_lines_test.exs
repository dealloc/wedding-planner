defmodule WeddingPlanner.OffersLinesTest do
  @moduledoc """
  Offer lines through `WeddingPlanner.Offers` (`docs/modules/offers-and-comparison.md`
  `CST-02`, `CST-04`, `CST-06`, `CST-11`, `CST-20` through `CST-23`, `CST-30` through
  `CST-33`, `CST-36`; `docs/04-cross-cutting.md` `XC-01`, `XC-10`–`XC-12`, `XC-40`–`XC-42`;
  `docs/modules/guests-and-events.md` `EVT-05`; `DR-18`, `DR-41`, `DR-42`).

  Ends with the representability tests: the normative offer inputs of O1–O6
  (`WeddingPlanner.NormativeExamples`) entered through the context and read back field
  by field. They are **not** tagged `example:` — C3 owns O1–O6; these only prove the
  inputs can be stored exactly.

  `async: false`: the event-deletion tests install the offer-line `EVT-05` provider in
  the (global) application env, restoring it afterwards.
  """
  use WeddingPlanner.DataCase, async: false

  import WeddingPlanner.OfferFixtures

  alias WeddingPlanner.Categories
  alias WeddingPlanner.Events
  alias WeddingPlanner.Log.Entry
  alias WeddingPlanner.NormativeExamples
  alias WeddingPlanner.Offers
  alias WeddingPlanner.Offers.Offer
  alias WeddingPlanner.Offers.OfferLine
  alias WeddingPlanner.Realtime

  defp eur(amount), do: WeddingPlanner.Money.new(amount)

  defp entries, do: Repo.all(from e in Entry, order_by: e.id)
  defp entries_after(count), do: entries() |> Enum.drop(count)

  defp reload(%OfferLine{id: id}), do: Repo.get!(OfferLine, id)

  defp install_offer_line_provider do
    original = Application.get_env(:wedding_planner, :event_reference_providers)

    Application.put_env(
      :wedding_planner,
      :event_reference_providers,
      (original || []) ++ [&Offers.event_offer_line_reference/1]
    )

    on_exit(fn ->
      if original,
        do: Application.put_env(:wedding_planner, :event_reference_providers, original),
        else: Application.delete_env(:wedding_planner, :event_reference_providers)
    end)
  end

  setup do
    scope = scope_fixture()
    category = category_fixture(scope)
    {:ok, catering} = Categories.create_service(scope, category, %{"name" => "Catering"})
    {:ok, sound} = Categories.create_service(scope, category, %{"name" => "Sound"})
    {:ok, dinner} = Events.create_event(scope, %{"name" => "Dinner"})
    offer = offer_fixture(scope, category, %{"vendor_name" => "Venue A"})

    %{
      scope: scope,
      category: category,
      catering: catering,
      sound: sound,
      dinner: dinner,
      offer: offer
    }
  end

  defp per_adult_attrs(ctx, amount_input \\ "85") do
    %{
      "service_id" => ctx.catering.id,
      "state" => "optional",
      "basis" => "per_adult",
      "event_id" => ctx.dinner.id,
      "amount_input" => amount_input
    }
  end

  defp ad_hoc_attrs(label, state \\ "mandatory", amount_input \\ "350") do
    %{"label" => label, "state" => state, "basis" => "flat", "amount_input" => amount_input}
  end

  defp line!(ctx, attrs, offer \\ nil) do
    {:ok, line} = Offers.create_line(ctx.scope, offer || ctx.offer, attrs)
    line
  end

  # -- create_line/3 ----------------------------------------------------------------------

  describe "create_line/3 (CST-20, CST-30, CST-31)" do
    test "stores a per-person service line, preloaded", ctx do
      assert {:ok, line} = Offers.create_line(ctx.scope, ctx.offer, per_adult_attrs(ctx))

      stored = reload(line)
      assert stored.offer_id == ctx.offer.id
      assert stored.service_id == ctx.catering.id
      assert stored.state == :optional
      assert stored.basis == :per_adult
      assert stored.event_id == ctx.dinner.id
      assert Money.equal?(stored.amount, eur(85))
      refute stored.enabled
      assert line.service.name == "Catering"
      assert line.event.name == "Dinner"
    end

    test "logs against the offer and broadcasts {:created, line} (XC-10, XC-01)", ctx do
      Realtime.subscribe(:offer_line)
      before = length(entries())

      line = line!(ctx, per_adult_attrs(ctx))

      assert [entry] = entries_after(before)
      assert entry.entity_type == "offer"
      assert entry.entity_id == ctx.offer.id

      assert entry.description ==
               "Wannes added line 'Catering (per adult, Dinner)' to offer 'Venue A'"

      id = line.id
      assert_received {Realtime, :offer_line, {:created, %OfferLine{id: ^id}}}
    end

    test "an ad hoc line is named by its label in the log", ctx do
      before = length(entries())
      line!(ctx, ad_hoc_attrs("Cleaning fee"))

      assert [%{description: "Wannes added line 'Cleaning fee' to offer 'Venue A'"}] =
               entries_after(before)
    end

    test "a per-person line without an event is refused (CST-31)", ctx do
      attrs = Map.delete(per_adult_attrs(ctx), "event_id")
      assert {:error, changeset} = Offers.create_line(ctx.scope, ctx.offer, attrs)
      assert errors_on(changeset).event_id != []
      assert Repo.aggregate(OfferLine, :count) == 0
    end

    test "an event that does not exist is refused", ctx do
      attrs = Map.put(per_adult_attrs(ctx), "event_id", ctx.dinner.id + 1000)
      assert {:error, changeset} = Offers.create_line(ctx.scope, ctx.offer, attrs)
      assert "does not exist" in errors_on(changeset).event_id
    end

    test "a service of another category is refused on service_id (DR-41)", ctx do
      other = category_fixture(ctx.scope, %{"name" => "Catering"})
      {:ok, foreign} = Categories.create_service(ctx.scope, other, %{"name" => "Drinks"})

      assert {:error, changeset} =
               Offers.create_line(ctx.scope, ctx.offer, %{
                 "service_id" => foreign.id,
                 "state" => "included"
               })

      assert errors_on(changeset).service_id != []
      assert Repo.aggregate(OfferLine, :count) == 0
    end

    test "a service may have several lines in one offer (CST-23)", ctx do
      line!(ctx, per_adult_attrs(ctx))

      line!(ctx, %{
        "service_id" => ctx.catering.id,
        "state" => "optional",
        "basis" => "per_child",
        "event_id" => ctx.dinner.id,
        "amount_input" => "40"
      })

      assert Categories.service_line_count(ctx.catering) == 2
    end

    test "an unknown line submitted with an amount stores no amount (DR-41)", ctx do
      line =
        line!(ctx, %{
          "service_id" => ctx.sound.id,
          "state" => "unknown",
          "basis" => "flat",
          "amount_input" => "85"
        })

      stored = reload(line)
      assert is_nil(stored.amount)
      assert is_nil(stored.basis)
    end

    test "a flat line submitted with an event and included quantity stores neither", ctx do
      line =
        line!(ctx, %{
          "service_id" => ctx.sound.id,
          "state" => "optional",
          "basis" => "flat",
          "event_id" => ctx.dinner.id,
          "included_quantity" => "50",
          "amount_input" => "500"
        })

      stored = reload(line)
      assert is_nil(stored.event_id)
      assert is_nil(stored.included_quantity)
    end

    test "a string under the typed amount key is refused, never read as money (DR-18)", ctx do
      attrs = %{
        "label" => "Base",
        "state" => "mandatory",
        "basis" => "flat",
        "amount" => "7641.50"
      }

      assert {:error, changeset} = Offers.create_line(ctx.scope, ctx.offer, attrs)
      assert errors_on(changeset).amount_input != []
    end
  end

  describe "line VAT rate (CST-33, CST-36 step 5, DR-41)" do
    test "is refused on a VAT-inclusive offer", ctx do
      attrs = Map.put(per_adult_attrs(ctx), "vat_rate_input", "12")
      assert {:error, changeset} = Offers.create_line(ctx.scope, ctx.offer, attrs)
      assert errors_on(changeset).vat_rate_input != []
    end

    test "is accepted on a VAT-exclusive offer, and retained after it turns inclusive", ctx do
      {:ok, offer} =
        Offers.update_offer(ctx.scope, ctx.offer, %{
          "vat_basis" => "exclusive",
          "vat_rate_input" => "21"
        })

      line = line!(ctx, Map.put(per_adult_attrs(ctx), "vat_rate_input", "12"), offer)
      assert reload(line).vat_rate_bp == 1200

      {:ok, _} = Offers.update_offer(ctx.scope, offer, %{"vat_basis" => "inclusive"})
      assert reload(line).vat_rate_bp == 1200

      # Editing another field keeps it; setting a new rate is now refused.
      {:ok, edited} = Offers.update_line(ctx.scope, line, %{"amount_input" => "90"})
      assert reload(edited).vat_rate_bp == 1200
      assert Decimal.equal?(OfferLine.vat_rate(reload(edited)), Decimal.new("0.12"))

      assert {:error, changeset} =
               Offers.update_line(ctx.scope, edited, %{"vat_rate_input" => "6"})

      assert errors_on(changeset).vat_rate_input != []

      # Clearing it is always allowed.
      {:ok, cleared} = Offers.update_line(ctx.scope, edited, %{"vat_rate_input" => ""})
      assert is_nil(reload(cleared).vat_rate_bp)
    end
  end

  # -- list_lines/1 -----------------------------------------------------------------------

  describe "list_lines/1 (DR-41 display order)" do
    test "service lines in service order (then id), then ad hoc lines by id", ctx do
      cleaning = line!(ctx, ad_hoc_attrs("Cleaning fee"))
      sound = line!(ctx, %{"service_id" => ctx.sound.id, "state" => "included"})
      adults = line!(ctx, per_adult_attrs(ctx))
      base = line!(ctx, ad_hoc_attrs("Base price", "mandatory", "4000"))

      children =
        line!(ctx, %{
          "service_id" => ctx.catering.id,
          "state" => "optional",
          "basis" => "per_child",
          "event_id" => ctx.dinner.id,
          "amount_input" => "40"
        })

      assert Enum.map(Offers.list_lines(ctx.offer), & &1.id) ==
               [adults.id, children.id, sound.id, cleaning.id, base.id]

      :ok = Categories.move_service(ctx.scope, ctx.sound, :up)

      lines = Offers.list_lines(ctx.offer)
      assert Enum.map(lines, & &1.id) == [sound.id, adults.id, children.id, cleaning.id, base.id]
      assert %{service: %{name: "Sound"}} = hd(lines)
    end

    test "only the offer's own lines", ctx do
      other = offer_fixture(ctx.scope, ctx.category, %{"vendor_name" => "Venue B"})
      line!(ctx, ad_hoc_attrs("Elsewhere"), other)
      assert Offers.list_lines(ctx.offer) == []
    end
  end

  # -- update_line/3 ----------------------------------------------------------------------

  describe "update_line/3 (XC-10, XC-01)" do
    test "logs one entry per changed field, money via Format.money, and broadcasts", ctx do
      line = line!(ctx, per_adult_attrs(ctx))
      Realtime.subscribe(:offer_line)
      before = length(entries())

      assert {:ok, updated} =
               Offers.update_line(ctx.scope, line, %{
                 "amount_input" => "90",
                 "minimum_charge_input" => "6.800"
               })

      assert Enum.map(entries_after(before), & &1.description) == [
               "Wannes changed the amount of line 'Catering (per adult, Dinner)' in offer 'Venue A': € 85,00 → € 90,00",
               "Wannes changed the minimum charge of line 'Catering (per adult, Dinner)' in offer 'Venue A': none → € 6.800,00"
             ]

      assert Enum.all?(entries_after(before), &(&1.entity_id == ctx.offer.id))
      id = updated.id
      assert_received {Realtime, :offer_line, {:updated, %OfferLine{id: ^id}}}
    end

    test "re-typing an equal amount changes and logs nothing", ctx do
      line = line!(ctx, per_adult_attrs(ctx, "85"))
      before = length(entries())
      {:ok, _} = Offers.update_line(ctx.scope, line, %{"amount_input" => "85,00"})
      assert entries_after(before) == []
    end

    test "event and state wording; clearing on an unpriced state is logged", ctx do
      {:ok, reception} = Events.create_event(ctx.scope, %{"name" => "Reception"})
      line = line!(ctx, per_adult_attrs(ctx))
      before = length(entries())

      {:ok, line} = Offers.update_line(ctx.scope, line, %{"event_id" => reception.id})

      assert [%{description: desc}] = entries_after(before)

      assert desc ==
               "Wannes changed the event of line 'Catering (per adult, Dinner)' in offer 'Venue A': Dinner → Reception"

      before = length(entries())
      {:ok, line} = Offers.update_line(ctx.scope, line, %{"state" => "not_offered"})

      assert Enum.map(entries_after(before), & &1.description) == [
               "Wannes changed the state of line 'Catering (per adult, Reception)' in offer 'Venue A': optional → not offered",
               "Wannes changed the pricing basis of line 'Catering (per adult, Reception)' in offer 'Venue A': per adult → none",
               "Wannes changed the event of line 'Catering (per adult, Reception)' in offer 'Venue A': Reception → none",
               "Wannes changed the amount of line 'Catering (per adult, Reception)' in offer 'Venue A': € 85,00 → none"
             ]

      assert Offers.line_label(line) == "Catering (not offered)"
    end

    test "editing an invalid line's amount keeps it invalid; an event or flat repairs it (XC-42)",
         ctx do
      install_offer_line_provider()
      line = line!(ctx, per_adult_attrs(ctx))
      {:ok, _} = Events.delete_event(ctx.scope, ctx.dinner)
      invalid = reload(line)
      assert OfferLine.invalid?(invalid)

      {:ok, edited} = Offers.update_line(ctx.scope, invalid, %{"amount_input" => "90"})
      assert OfferLine.invalid?(reload(edited))
      assert Money.equal?(reload(edited).amount, eur(90))

      {:ok, reception} = Events.create_event(ctx.scope, %{"name" => "Reception"})
      {:ok, repaired} = Offers.update_line(ctx.scope, edited, %{"event_id" => reception.id})
      refute OfferLine.invalid?(reload(repaired))

      other = line!(ctx, Map.put(per_adult_attrs(ctx), "event_id", reception.id))
      {:ok, _} = Events.delete_event(ctx.scope, reception)
      {:ok, flat} = Offers.update_line(ctx.scope, reload(other), %{"basis" => "flat"})
      refute OfferLine.invalid?(reload(flat))
    end
  end

  # -- delete_line/2 ----------------------------------------------------------------------

  describe "delete_line/2" do
    test "deletes, logs against the offer and broadcasts {:deleted, id}", ctx do
      line = line!(ctx, ad_hoc_attrs("Cleaning fee"))
      Realtime.subscribe(:offer_line)
      before = length(entries())

      assert {:ok, _} = Offers.delete_line(ctx.scope, line)

      refute Repo.get(OfferLine, line.id)

      assert [%{description: "Wannes deleted line 'Cleaning fee' from offer 'Venue A'"} = entry] =
               entries_after(before)

      assert entry.entity_id == ctx.offer.id
      id = line.id
      assert_received {Realtime, :offer_line, {:deleted, ^id}}
    end
  end

  # -- set_line_enabled/3 -----------------------------------------------------------------

  describe "set_line_enabled/3 (CST-22)" do
    test "an optional ad hoc line starts off and can be turned on and off, logged", ctx do
      line = line!(ctx, ad_hoc_attrs("Corkage fee", "optional", "5"))
      refute reload(line).enabled
      Realtime.subscribe(:offer_line)
      before = length(entries())

      assert {:ok, on} = Offers.set_line_enabled(ctx.scope, line, true)
      assert reload(on).enabled
      id = line.id
      assert_received {Realtime, :offer_line, {:updated, %OfferLine{id: ^id, enabled: true}}}

      assert {:ok, off} = Offers.set_line_enabled(ctx.scope, on, false)
      refute reload(off).enabled

      assert Enum.map(entries_after(before), & &1.description) == [
               "Wannes turned on 'Corkage fee' in offer 'Venue A'",
               "Wannes turned off 'Corkage fee' in offer 'Venue A'"
             ]
    end

    test "is refused for a mandatory ad hoc line and for a service line", ctx do
      mandatory = line!(ctx, ad_hoc_attrs("Cleaning fee"))
      service_line = line!(ctx, per_adult_attrs(ctx))

      assert {:error, :not_optional_ad_hoc} = Offers.set_line_enabled(ctx.scope, mandatory, true)

      assert {:error, :not_optional_ad_hoc} =
               Offers.set_line_enabled(ctx.scope, service_line, true)

      refute reload(mandatory).enabled
      refute reload(service_line).enabled
    end

    test "changing an enabled line to mandatory resets enabled", ctx do
      line = line!(ctx, ad_hoc_attrs("Corkage fee", "optional", "5"))
      {:ok, on} = Offers.set_line_enabled(ctx.scope, line, true)
      before = length(entries())

      {:ok, mandatory} = Offers.update_line(ctx.scope, on, %{"state" => "mandatory"})
      refute reload(mandatory).enabled

      assert "Wannes changed the on/off toggle of line 'Corkage fee' in offer 'Venue A': on → off" in Enum.map(
               entries_after(before),
               & &1.description
             )
    end
  end

  # -- create_simple_offer/3 --------------------------------------------------------------

  describe "create_simple_offer/3 (CST-11)" do
    setup %{scope: scope} do
      %{attire: category_fixture(scope, %{"name" => "Attire"})}
    end

    test "creates exactly one mandatory flat ad hoc 'Price' line, one summary + two children",
         %{scope: scope, attire: attire} do
      Realtime.subscribe(:offer)
      Realtime.subscribe(:offer_line)
      before = length(entries())

      assert {:ok, %Offer{} = offer} =
               Offers.create_simple_offer(scope, attire, %{
                 vendor_name: "Bridal Boutique",
                 amount_input: "1.800"
               })

      assert offer.category_id == attire.id
      assert offer.vat_basis == :inclusive
      assert offer.status == :considering

      assert [line] = Offers.list_lines(offer)
      assert line.label == "Price"
      assert is_nil(line.service_id)
      assert line.state == :mandatory
      assert line.basis == :flat
      assert Money.equal?(line.amount, eur(1800))
      refute line.enabled

      assert [summary | children] = entries_after(before)
      assert is_nil(summary.entity_type)

      assert summary.description ==
               "Wannes added offer 'Bridal Boutique' to Attire (one flat price € 1.800,00)"

      assert Enum.map(children, & &1.description) == [
               "Wannes added offer 'Bridal Boutique' to Attire",
               "Wannes added line 'Price' to offer 'Bridal Boutique'"
             ]

      assert Enum.all?(children, &(&1.parent_id == summary.id and &1.entity_id == offer.id))

      offer_id = offer.id
      line_id = line.id
      assert_received {Realtime, :offer, {:created, %Offer{id: ^offer_id}}}
      assert_received {Realtime, :offer_line, {:created, %OfferLine{id: ^line_id}}}
    end

    test "string-keyed params and a VAT-exclusive basis work", %{scope: scope, attire: attire} do
      assert {:ok, offer} =
               Offers.create_simple_offer(scope, attire, %{
                 "vendor_name" => "Suits & Co",
                 "amount_input" => "950,50",
                 "vat_basis" => "exclusive",
                 "vat_rate_input" => "21"
               })

      assert offer.vat_basis == :exclusive
      assert [line] = Offers.list_lines(offer)
      assert Money.equal?(line.amount, eur(Decimal.new("950.50")))
      assert is_nil(line.vat_rate_bp)
    end

    test "invalid input writes nothing and reports both fields on the offer changeset",
         %{scope: scope, attire: attire} do
      before = length(entries())

      assert {:error, changeset} =
               Offers.create_simple_offer(scope, attire, %{
                 "vendor_name" => "",
                 "amount_input" => "1500.50"
               })

      assert changeset.data.__struct__ == Offer
      assert errors_on(changeset).vendor_name != []
      assert errors_on(changeset).amount_input != []

      assert {:error, changeset} =
               Offers.create_simple_offer(scope, attire, %{"vendor_name" => "Boutique"})

      assert "can't be blank" in errors_on(changeset).amount_input

      assert entries_after(before) == []
      assert Offers.list_offers(attire) == []
      assert Repo.aggregate(OfferLine, :count) == 0
    end
  end

  # -- line_label/1 -----------------------------------------------------------------------

  describe "line_label/1 (DR-41)" do
    test "service lines by basis and event, or by state; ad hoc by label", ctx do
      assert Offers.line_label(line!(ctx, per_adult_attrs(ctx))) == "Catering (per adult, Dinner)"

      assert Offers.line_label(line!(ctx, %{"service_id" => ctx.sound.id, "state" => "included"})) ==
               "Sound (included)"

      assert Offers.line_label(
               line!(ctx, %{
                 "service_id" => ctx.sound.id,
                 "state" => "optional",
                 "basis" => "flat",
                 "amount_input" => "500"
               })
             ) == "Sound (optional)"

      attendee =
        line!(ctx, %{
          "service_id" => ctx.catering.id,
          "state" => "mandatory",
          "basis" => "per_attendee",
          "event_id" => ctx.dinner.id,
          "amount_input" => "12"
        })

      assert Offers.line_label(attendee) == "Catering (per attendee, Dinner)"
      assert Offers.line_label(reload(attendee)) == "Catering (per attendee, Dinner)"
      assert Offers.line_label(line!(ctx, ad_hoc_attrs("Cleaning fee"))) == "Cleaning fee"
    end
  end

  # -- services: count, delete guard, merge (CST-04, CST-06) ------------------------------

  describe "services (CST-04, CST-06)" do
    test "service_line_count/1 is a real count; delete_service/2 refuses a service with lines",
         ctx do
      assert Categories.service_line_count(ctx.sound) == 0
      line = line!(ctx, %{"service_id" => ctx.sound.id, "state" => "unknown"})
      assert Categories.service_line_count(ctx.sound) == 1
      assert Offers.count_service_lines(ctx.sound) == 1

      assert {:error, :has_lines} = Categories.delete_service(ctx.scope, ctx.sound)
      assert Categories.get_service!(ctx.sound.id)

      {:ok, _} = Offers.delete_line(ctx.scope, line)
      assert {:ok, _} = Categories.delete_service(ctx.scope, ctx.sound)
    end

    test "merge moves every line to the survivor, one child entry per affected offer", ctx do
      {:ok, absorbed} =
        Categories.create_service(ctx.scope, ctx.category, %{"name" => "Sound system"})

      venue_b = offer_fixture(ctx.scope, ctx.category, %{"vendor_name" => "Venue B"})

      a1 = line!(ctx, %{"service_id" => absorbed.id, "state" => "included"})

      a2 =
        line!(ctx, %{
          "service_id" => absorbed.id,
          "state" => "optional",
          "basis" => "flat",
          "amount_input" => "200"
        })

      b1 = line!(ctx, %{"service_id" => absorbed.id, "state" => "unknown"}, venue_b)
      untouched = line!(ctx, per_adult_attrs(ctx))

      Realtime.subscribe(:offer_line)
      before = length(entries())

      assert {:ok, _} = Categories.merge_services(ctx.scope, absorbed, ctx.sound)

      for line <- [a1, a2, b1], do: assert(reload(line).service_id == ctx.sound.id)
      assert reload(untouched).service_id == ctx.catering.id
      assert Categories.service_line_count(ctx.sound) == 3
      refute Repo.get(Categories.Service, absorbed.id)

      [summary | children] = entries_after(before)
      assert summary.description == "Wannes merged 'Sound system' into 'Sound' in Venue"
      assert Enum.all?(children, &(&1.parent_id == summary.id))

      moves = Enum.filter(children, &(&1.entity_type == "offer"))

      assert Enum.map(moves, &{&1.entity_id, &1.description}) == [
               {ctx.offer.id,
                "Wannes moved 2 lines of offer 'Venue A' from 'Sound system' to 'Sound' (services merged)"},
               {venue_b.id,
                "Wannes moved 1 line of offer 'Venue B' from 'Sound system' to 'Sound' (services merged)"}
             ]

      sound_id = ctx.sound.id

      for %{id: id} <- [a1, a2, b1] do
        assert_received {Realtime, :offer_line,
                         {:updated, %OfferLine{id: ^id, service_id: ^sound_id}}}
      end
    end
  end

  # -- event deletion (XC-41, DR-42, EVT-05) ----------------------------------------------

  describe "event deletion (XC-41, XC-42, DR-42, EVT-05)" do
    setup ctx do
      install_offer_line_provider()

      adults = line!(ctx, per_adult_attrs(ctx))

      children =
        line!(ctx, %{
          "service_id" => ctx.catering.id,
          "state" => "optional",
          "basis" => "per_child",
          "event_id" => ctx.dinner.id,
          "amount_input" => "40"
        })

      flat = line!(ctx, ad_hoc_attrs("Cleaning fee"))
      %{adults: adults, children: children, flat: flat}
    end

    test "the provider counts the lines; nil for an unreferenced event", ctx do
      assert Offers.event_offer_line_reference(ctx.dinner) ==
               %{label: "2 offer lines (they become invalid)", count: 2}

      assert %{label: "2 offer lines (they become invalid)", count: 2} in Events.affected_references(
               ctx.dinner
             )

      {:ok, brunch} = Events.create_event(ctx.scope, %{"name" => "Brunch"})
      assert is_nil(Offers.event_offer_line_reference(brunch))

      line!(ctx, Map.put(per_adult_attrs(ctx), "event_id", brunch.id))

      assert Offers.event_offer_line_reference(brunch) ==
               %{label: "1 offer line (it becomes invalid)", count: 1}
    end

    test "per-person lines become invalid, one child per line, event gone, flat untouched", ctx do
      Realtime.subscribe(:offer_line)
      flat_before = reload(ctx.flat)
      before = length(entries())

      assert {:ok, _} = Events.delete_event(ctx.scope, ctx.dinner)

      refute Repo.get(Events.Event, ctx.dinner.id)
      assert OfferLine.invalid?(reload(ctx.adults))
      assert OfferLine.invalid?(reload(ctx.children))
      assert Money.equal?(reload(ctx.adults).amount, eur(85))
      assert reload(ctx.flat) == flat_before
      refute OfferLine.invalid?(reload(ctx.flat))

      [summary | children] = entries_after(before)
      assert summary.description == "Wannes deleted event 'Dinner'"
      assert Enum.all?(children, &(&1.parent_id == summary.id))

      line_entries = Enum.filter(children, &(&1.entity_type == "offer"))

      assert Enum.map(line_entries, &{&1.entity_id, &1.description}) == [
               {ctx.offer.id,
                "Wannes deleted event 'Dinner': line 'Catering (per adult)' in offer 'Venue A' is now invalid"},
               {ctx.offer.id,
                "Wannes deleted event 'Dinner': line 'Catering (per child)' in offer 'Venue A' is now invalid"}
             ]

      for %{id: id} <- [ctx.adults, ctx.children] do
        assert_received {Realtime, :offer_line, {:updated, %OfferLine{id: ^id, event_id: nil}}}
      end

      refute_received {Realtime, :offer_line, {:updated, %OfferLine{label: "Cleaning fee"}}}
    end
  end

  # -- delete_offer/2 and its effects -----------------------------------------------------

  describe "delete_offer/2 with lines (XC-24, XC-40, DR-40)" do
    test "effects list the lines and the references", ctx do
      assert Offers.offer_deletion_effects(ctx.offer) == []

      line!(ctx, per_adult_attrs(ctx))
      line!(ctx, ad_hoc_attrs("Cleaning fee"))

      {:ok, _} =
        WeddingPlanner.References.create_url_reference(
          ctx.scope,
          Offers.reference_owner(ctx.offer),
          %{"label" => "Site", "url" => "https://a.example"}
        )

      assert Offers.offer_deletion_effects(ctx.offer) == [
               %{label: "2 lines", count: 2},
               %{label: "1 reference is deleted (1 link)", count: 1}
             ]
    end

    test "deletes the lines and references, one child each, broadcasts each line", ctx do
      adults = line!(ctx, per_adult_attrs(ctx))
      cleaning = line!(ctx, ad_hoc_attrs("Cleaning fee"))

      {:ok, ref} =
        WeddingPlanner.References.create_url_reference(
          ctx.scope,
          Offers.reference_owner(ctx.offer),
          %{"label" => "Site", "url" => "https://a.example"}
        )

      Realtime.subscribe(:offer_line)
      before = length(entries())

      assert {:ok, _} = Offers.delete_offer(ctx.scope, ctx.offer)

      refute Repo.get(Offer, ctx.offer.id)
      assert Repo.aggregate(OfferLine, :count) == 0
      refute Repo.get(WeddingPlanner.References.Reference, ref.id)

      [summary | children] = entries_after(before)
      assert summary.description == "Wannes deleted offer 'Venue A'"
      assert length(children) == 3
      assert Enum.all?(children, &(&1.parent_id == summary.id))

      descriptions = Enum.map(children, & &1.description)

      assert "Wannes deleted line 'Catering (per adult, Dinner)' from offer 'Venue A' (offer deleted)" in descriptions

      assert "Wannes deleted line 'Cleaning fee' from offer 'Venue A' (offer deleted)" in descriptions

      for %{id: id} <- [adults, cleaning] do
        assert_received {Realtime, :offer_line, {:deleted, ^id}}
      end
    end
  end

  # -- representability of the normative offer inputs (O1–O6) -----------------------------

  describe "normative offer inputs are representable (O1–O6 inputs, DR-41)" do
    # Builds the category with the docs' services and priorities, and a "Dinner" event.
    defp normative_category!(scope, %{name: name, services: services}) do
      {:ok, category} = Categories.create_category(scope, %{"name" => name})

      services =
        Map.new(services, fn %{name: service_name, priority: priority} ->
          {:ok, service} =
            Categories.create_service(scope, category, %{
              "name" => service_name,
              "wanted_priority" => Atom.to_string(priority)
            })

          {service_name, service}
        end)

      {category, services}
    end

    defp dinner!(scope) do
      case Enum.find(Events.list_events(), &(&1.name == "Dinner")) do
        nil -> elem(Events.create_event(scope, %{"name" => "Dinner"}), 1)
        event -> event
      end
    end

    defp bp(nil), do: nil
    defp bp(%Decimal{} = rate), do: rate |> Decimal.mult(10_000) |> Decimal.to_integer()

    # Enters one transcribed line through the context with typed values only: the amount
    # and minimum charge as the `%Money{}` the fixture holds, the rate as basis points —
    # never a string amount (DR-18).
    defp enter_line!(scope, offer, services, event, line) do
      attrs =
        %{
          "state" => Atom.to_string(line.state),
          "amount" => line.amount,
          "minimum_charge" => line.minimum_charge,
          "included_quantity" => line.included,
          "vat_rate_bp" => bp(line.vat_rate)
        }
        |> Map.merge(
          if line.service,
            do: %{"service_id" => Map.fetch!(services, line.service).id},
            else: %{"label" => line.label}
        )
        |> Map.merge(if line.basis, do: %{"basis" => Atom.to_string(line.basis)}, else: %{})
        |> Map.merge(if line.event, do: %{"event_id" => event.id}, else: %{})

      {:ok, stored} = Offers.create_line(scope, offer, attrs)
      {line, stored.id}
    end

    defp assert_money(nil, stored, what), do: assert(is_nil(stored), what)

    # Exact, not merely numerically equal: the stored Decimal is the fixture's Decimal
    # digit for digit (a value that went through a formatted string or a rounding step
    # would come back with a different exponent even when the number agrees).
    defp assert_money(%Money{} = expected, stored, what) do
      assert %Money{currency: :EUR} = stored, what
      assert Money.equal?(stored, expected), what

      assert Decimal.to_string(stored.amount, :raw) == Decimal.to_string(expected.amount, :raw),
             what
    end

    defp assert_line_readback!(entered, services, event) do
      for {line, id} <- entered do
        stored = Repo.get!(OfferLine, id)
        what = "line #{line.number} (#{line.label})"

        if line.service do
          assert stored.service_id == Map.fetch!(services, line.service).id, what
          assert is_nil(stored.label), what
        else
          assert is_nil(stored.service_id), what
          assert stored.label == line.label, what
        end

        assert stored.state == line.state, what
        assert stored.basis == line.basis, what
        assert stored.event_id == if(line.event, do: event.id), what
        assert stored.included_quantity == line.included, what
        assert_money(line.amount, stored.amount, what <> " amount")
        assert_money(line.minimum_charge, stored.minimum_charge, what <> " minimum charge")

        case line.vat_rate do
          nil -> assert is_nil(OfferLine.vat_rate(stored)), what
          rate -> assert Decimal.equal?(OfferLine.vat_rate(stored), rate), what
        end

        refute stored.enabled, what
        refute OfferLine.invalid?(stored), what
      end
    end

    test "normative offer inputs are representable: Venue A (all eight lines)", %{scope: scope} do
      given = NormativeExamples.venue_a()
      {category, services} = normative_category!(scope, NormativeExamples.venue_category())
      dinner = dinner!(scope)

      {:ok, offer} =
        Offers.create_offer(scope, category, %{"vendor_name" => given.vendor})

      entered = Enum.map(given.lines, &enter_line!(scope, offer, services, dinner, &1))

      stored_offer = Repo.get!(Offer, offer.id)
      assert stored_offer.vat_basis == given.vat_basis
      assert is_nil(Offer.vat_rate(stored_offer))
      assert is_nil(stored_offer.minimum_spend)

      assert length(Offers.list_lines(offer)) == 8
      assert_line_readback!(entered, services, dinner)

      # Lines 5 (Sound, included) and 8 (Late-night snack, unknown) carry no pricing.
      for {%{number: n}, id} <- entered, n in [5, 8] do
        stored = Repo.get!(OfferLine, id)

        assert %{basis: nil, amount: nil, event_id: nil, included_quantity: nil} = stored
        assert %{minimum_charge: nil, vat_rate_bp: nil} = stored
      end
    end

    test "normative offer inputs are representable: Venue B (no Catering line, or not offered)",
         %{scope: scope} do
      given = NormativeExamples.venue_b()
      {category, services} = normative_category!(scope, NormativeExamples.venue_category())
      catering = Map.fetch!(services, "Catering")

      assert given.catering == [:no_line, :not_offered_line]

      {:ok, no_line} = Offers.create_offer(scope, category, %{"vendor_name" => given.vendor})
      assert Offers.list_lines(no_line) == []

      {:ok, not_offered} = Offers.create_offer(scope, category, %{"vendor_name" => given.vendor})

      {:ok, line} =
        Offers.create_line(scope, not_offered, %{
          "service_id" => catering.id,
          "state" => "not_offered"
        })

      stored = Repo.get!(OfferLine, line.id)
      assert stored.service_id == catering.id
      assert stored.state == :not_offered
      assert %{basis: nil, amount: nil, event_id: nil, minimum_charge: nil} = stored
      assert Offers.list_lines(not_offered) |> Enum.map(& &1.id) == [line.id]
      assert Offers.list_lines(no_line) == []
    end

    test "normative offer inputs are representable: Caterer C (exclusive, mixed rates, minimums)",
         %{scope: scope} do
      given = NormativeExamples.caterer_c()
      {category, services} = normative_category!(scope, NormativeExamples.catering_category())
      dinner = dinner!(scope)

      # The offer's own inputs go through `Offer.changeset/2`'s text inputs (task 49 has
      # no typed path): the rate as basis points rendered by `VatRate.format/1`, the
      # minimum spend as the plain integer the fixture holds — neither is a formatted
      # money string, and both are read back exactly below.
      default_bp = bp(given.default_vat_rate)
      assert default_bp == 2100
      assert Decimal.equal?(given.minimum_spend.amount, Decimal.new(7000))

      {:ok, offer} =
        Offers.create_offer(scope, category, %{
          "vendor_name" => given.vendor,
          "vat_basis" => Atom.to_string(given.vat_basis),
          "vat_rate_input" => WeddingPlanner.Offers.VatRate.format(default_bp),
          "minimum_spend_input" => "7000"
        })

      entered = Enum.map(given.lines, &enter_line!(scope, offer, services, dinner, &1))

      stored_offer = Repo.get!(Offer, offer.id)
      assert stored_offer.vat_basis == :exclusive
      assert Decimal.equal?(Offer.vat_rate(stored_offer), given.default_vat_rate)
      assert_money(given.minimum_spend, stored_offer.minimum_spend, "minimum spend")

      assert length(Offers.list_lines(offer)) == 4
      assert_line_readback!(entered, services, dinner)

      # The two rates the doc mixes, spelled out (CST-33, D-21): lines 1–2 at 12 %,
      # lines 3–4 on the offer default; line 4's minimum charge is € 200 excl. (CST-36).
      rates = Map.new(entered, fn {line, id} -> {line.number, Repo.get!(OfferLine, id)} end)
      assert Decimal.equal?(OfferLine.vat_rate(rates[1]), Decimal.new("0.12"))
      assert Decimal.equal?(OfferLine.vat_rate(rates[2]), Decimal.new("0.12"))
      assert is_nil(rates[3].vat_rate_bp)
      assert is_nil(rates[4].vat_rate_bp)
      assert Money.equal?(rates[4].minimum_charge, eur(200))
    end
  end
end
