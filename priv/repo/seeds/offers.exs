defmodule WeddingPlanner.Seeds.Offers do
  @moduledoc """
  `DR-26` Q4 demo offers and lines (task 52; `docs/modules/offers-and-comparison.md`
  `CST-02`, `CST-11`, `CST-20` through `CST-33`, `CST-36`): the Venue worked example
  ("Venue A", all eight lines, against the seeded "Dinner" event), a second Venue offer
  ("Kasteel Heers") with a couple of lines, the Catering VAT-exclusive worked example
  ("Caterer C", mixed 12 %/21 % rates, a minimum charge and a minimum spend), and an
  Attire quick offer (`CST-11`). Every line goes through
  `WeddingPlanner.Offers.create_line/3` (or `create_simple_offer/3`), never
  `Repo.insert!` directly, so each gets a real activity-log entry (`XC-10`) and real
  validation, exactly as `priv/repo/seeds.exs`'s own moduledoc requires. Amounts use the
  typed-`Money` programmatic path the `WeddingPlanner.Offers.OfferLine` moduledoc
  sanctions for seeds/fixtures (`DR-18`) rather than parsed nl-BE strings.

  One override (task 66, `DR-56`): "Venue A" has its nice-to-have "Late-night snack"
  turned off via `WeddingPlanner.Offers.toggle_override/3` — the same call the matrix's
  own cell toggle makes — so the demo category page shows the override marker without
  any manual clicking.

  Idempotent: runs only while the `offers` table is empty — see `priv/repo/seeds.exs`.
  Depends on `seeds/categories.exs` (Venue/Catering/Attire and their services) and
  `seeds/events.exs` ("Dinner") having already run.
  """

  alias WeddingPlanner.Accounts.Scope
  alias WeddingPlanner.Categories
  alias WeddingPlanner.Categories.Category
  alias WeddingPlanner.Events
  alias WeddingPlanner.Offers
  alias WeddingPlanner.Offers.Offer
  alias WeddingPlanner.Repo

  @spec run(Scope.t()) :: :ok
  def run(%Scope{} = scope) do
    if Repo.aggregate(Offer, :count) == 0 do
      seed_venue(scope)
      seed_catering(scope)
      seed_attire(scope)
      IO.puts("offers: created demo offers and lines")
    else
      IO.puts("skipping offers — already has data")
    end

    :ok
  end

  # -- Venue: the CST-36-adjacent worked example (docs' "Venue A", all eight lines),
  # plus a second offer with a couple of lines ------------------------------------------

  defp seed_venue(scope) do
    category = category!("Venue")
    dinner = event!("Dinner")
    seating = service!(category, "Seating")
    catering = service!(category, "Catering")
    sound = service!(category, "Sound")
    garden = service!(category, "Garden ceremony")
    snack = service!(category, "Late-night snack")

    {:ok, venue_a} = Offers.create_offer(scope, category, %{"vendor_name" => "Venue A"})

    [
      %{
        "label" => "Base price",
        "state" => "mandatory",
        "basis" => "flat",
        "amount" => eur(4_000)
      },
      %{
        "service_id" => seating.id,
        "state" => "mandatory",
        "basis" => "per_attendee",
        "event_id" => dinner.id,
        "amount" => eur(12),
        "included_quantity" => 50
      },
      %{
        "service_id" => catering.id,
        "state" => "optional",
        "basis" => "per_adult",
        "event_id" => dinner.id,
        "amount" => eur(85),
        "minimum_charge" => eur(6_800)
      },
      %{
        "service_id" => catering.id,
        "state" => "optional",
        "basis" => "per_child",
        "event_id" => dinner.id,
        "amount" => eur(40)
      },
      %{"service_id" => sound.id, "state" => "included"},
      %{
        "service_id" => garden.id,
        "state" => "optional",
        "basis" => "flat",
        "amount" => eur(500)
      },
      %{
        "label" => "Cleaning fee",
        "state" => "mandatory",
        "basis" => "flat",
        "amount" => eur(350)
      },
      %{"service_id" => snack.id, "state" => "unknown"}
    ]
    |> Enum.each(&create_line!(scope, venue_a, &1))

    # Task 66 (DR-56): a demo override — Late-night snack turned off for Venue A — so the
    # matrix shows its marker without any manual clicking.
    {:ok, _} = Offers.toggle_override(scope, venue_a, snack)

    {:ok, kasteel_heers} =
      Offers.create_offer(scope, category, %{"vendor_name" => "Kasteel Heers"})

    [
      %{
        "label" => "Base price",
        "state" => "mandatory",
        "basis" => "flat",
        "amount" => eur(3_800)
      },
      %{
        "service_id" => catering.id,
        "state" => "optional",
        "basis" => "per_adult",
        "event_id" => dinner.id,
        "amount" => eur(90)
      }
    ]
    |> Enum.each(&create_line!(scope, kasteel_heers, &1))
  end

  # -- Catering: the CST-36 VAT-exclusive, mixed-rate, minimum-charge/minimum-spend
  # worked example ("Caterer C") ---------------------------------------------------------

  defp seed_catering(scope) do
    category = category!("Catering")
    dinner = event!("Dinner")
    dinner_catering = service!(category, "Dinner catering")
    drinks = service!(category, "Drinks")

    {:ok, caterer_c} =
      Offers.create_offer(scope, category, %{
        "vendor_name" => "Caterer C",
        "vat_basis" => "exclusive",
        "vat_rate_input" => "21",
        "minimum_spend_input" => "7.000"
      })

    [
      %{
        "service_id" => dinner_catering.id,
        "state" => "mandatory",
        "basis" => "per_adult",
        "event_id" => dinner.id,
        "amount" => eur(60),
        "vat_rate_bp" => 1200
      },
      %{
        "service_id" => dinner_catering.id,
        "state" => "mandatory",
        "basis" => "per_child",
        "event_id" => dinner.id,
        "amount" => eur(30),
        "vat_rate_bp" => 1200
      },
      %{
        "service_id" => drinks.id,
        "state" => "optional",
        "basis" => "per_attendee",
        "event_id" => dinner.id,
        "amount" => eur(25)
      },
      %{
        "label" => "Travel",
        "state" => "mandatory",
        "basis" => "flat",
        "amount" => eur(150),
        "minimum_charge" => eur(200)
      }
    ]
    |> Enum.each(&create_line!(scope, caterer_c, &1))
  end

  # -- Attire: the CST-11 quick offer -----------------------------------------------------

  defp seed_attire(scope) do
    category = category!("Attire")

    {:ok, _offer} =
      Offers.create_simple_offer(scope, category, %{
        "vendor_name" => "Bridal Boutique",
        "amount_input" => "1.800"
      })
  end

  # -- helpers -----------------------------------------------------------------------

  defp eur(amount), do: WeddingPlanner.Money.new(amount)

  defp create_line!(scope, offer, attrs) do
    {:ok, line} = Offers.create_line(scope, offer, attrs)
    line
  end

  defp category!(name) do
    Categories.list_categories() |> Enum.find(&(&1.name == name)) ||
      raise "seed category '#{name}' not found — run seeds/categories.exs first"
  end

  defp service!(%Category{} = category, name) do
    Categories.list_services(category) |> Enum.find(&(&1.name == name)) ||
      raise "seed service '#{name}' not found in '#{category.name}'"
  end

  defp event!(name) do
    Events.list_events() |> Enum.find(&(&1.name == name)) ||
      raise "seed event '#{name}' not found — run seeds/events.exs first"
  end
end
