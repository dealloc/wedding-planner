defmodule WeddingPlanner.NormativeOfferRows do
  @moduledoc """
  The frozen normative offers of `WeddingPlanner.NormativeExamples` (Venue A, Venue B,
  Caterer C) entered as **real database rows** through the contexts
  (`WeddingPlanner.Categories`, `WeddingPlanner.Events`, `WeddingPlanner.Offers`) — the
  counterpart of `WeddingPlanner.NormativeSnapshots`' in-memory structs. Test support
  only; needs a sandboxed `WeddingPlanner.DataCase`.

  Used by the representability tests (`WeddingPlanner.OffersLinesTest`) and the cost
  engine's round trip over the loaded snapshot (`WeddingPlanner.Valuation.OfferDbTest`).

  ## Money (`DR-18`, `DR-46`)

  Lines are entered with **typed** values only: amounts and minimum charges as the
  fixture's own `%Money{}`, rates as basis points. The offer's own rate and minimum
  spend have no typed path (task 49), so they go through the offer's text inputs:
  the rate as basis points rendered by `WeddingPlanner.Offers.VatRate.format/1`, the
  minimum spend as the plain integer the fixture holds (parsed by
  `WeddingPlanner.Money.parse/2`). Never a formatted money string, never `Money.new/2`
  with a string.

  ## Venue B is test construction, not normative data

  As in `WeddingPlanner.NormativeSnapshots`: Venue A's lines **without** the two Catering
  lines (3 and 4), plus, for the `:not_offered_line` variant, one Catering line in state
  `:not_offered`, numbered
  `WeddingPlanner.NormativeSnapshots.venue_b_not_offered_line_id/0`. None of this is in
  `docs/`.
  """

  alias WeddingPlanner.Categories
  alias WeddingPlanner.Categories.Category
  alias WeddingPlanner.Categories.Service
  alias WeddingPlanner.Events
  alias WeddingPlanner.Events.Event
  alias WeddingPlanner.NormativeExamples
  alias WeddingPlanner.NormativeSnapshots
  alias WeddingPlanner.Offers
  alias WeddingPlanner.Offers.Offer
  alias WeddingPlanner.Offers.VatRate

  @typedoc "Which normative offer to enter."
  @type which ::
          :venue_a | {:venue_b, :no_line} | {:venue_b, :not_offered_line} | :caterer_c

  @doc """
  Creates the category named in `category_map` (`NormativeExamples.venue_category/0` or
  `catering_category/0`) with its services and their wanted priorities, in the docs'
  order. Returns `{category, services_by_name}`.
  """
  @spec category!(WeddingPlanner.Accounts.Scope.t(), map()) ::
          {Category.t(), %{String.t() => Service.t()}}
  def category!(scope, %{name: name, services: services}) do
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

  @doc "The `Dinner` event, created on first use."
  @spec dinner!(WeddingPlanner.Accounts.Scope.t()) :: Event.t()
  def dinner!(scope) do
    case Enum.find(Events.list_events(), &(&1.name == "Dinner")) do
      nil -> elem(Events.create_event(scope, %{"couple_attends" => false, "name" => "Dinner"}), 1)
      event -> event
    end
  end

  @doc "A `Decimal` VAT fraction as basis points (`0.21` → `2100`); `nil` stays `nil`."
  @spec bp(Decimal.t() | nil) :: non_neg_integer() | nil
  def bp(nil), do: nil
  def bp(%Decimal{} = rate), do: rate |> Decimal.mult(10_000) |> Decimal.to_integer()

  @doc """
  Enters normative offer `which` in `category` (from `category!/2`, with its `services`)
  with its lines, per-person lines on `dinner`. Returns the offer and each line's
  database id keyed by the docs' line number.
  """
  @spec offer!(
          WeddingPlanner.Accounts.Scope.t(),
          which(),
          Category.t(),
          %{String.t() => Service.t()},
          Event.t()
        ) :: %{offer: Offer.t(), line_ids_by_number: %{pos_integer() => term()}}
  def offer!(scope, :venue_a, category, services, dinner) do
    given = NormativeExamples.venue_a()
    enter!(scope, category, services, dinner, offer_attrs(given), given.lines)
  end

  def offer!(scope, {:venue_b, variant}, category, services, dinner)
      when variant in [:no_line, :not_offered_line] do
    %{vendor: vendor, catering: variants} = NormativeExamples.venue_b()
    # Both variants are the fixture's own (O3); fail loudly if it ever stops listing one.
    true = variant in variants

    venue_a = NormativeExamples.venue_a()
    borrowed = Enum.reject(venue_a.lines, &(&1.service == "Catering"))

    extra =
      case variant do
        :no_line ->
          []

        :not_offered_line ->
          [
            %{
              number: NormativeSnapshots.venue_b_not_offered_line_id(),
              label: "Catering",
              service: "Catering",
              state: :not_offered,
              basis: nil,
              event: nil,
              amount: nil,
              included: nil,
              minimum_charge: nil,
              vat_rate: nil
            }
          ]
      end

    attrs = offer_attrs(%{venue_a | vendor: vendor})
    enter!(scope, category, services, dinner, attrs, borrowed ++ extra)
  end

  def offer!(scope, :caterer_c, category, services, dinner) do
    given = NormativeExamples.caterer_c()
    enter!(scope, category, services, dinner, offer_attrs(given), given.lines)
  end

  # -- entering -------------------------------------------------------------------------------

  defp enter!(scope, category, services, dinner, offer_attrs, lines) do
    {:ok, offer} = Offers.create_offer(scope, category, offer_attrs)

    ids =
      Map.new(lines, fn line ->
        {:ok, stored} = Offers.create_line(scope, offer, line_attrs(line, services, dinner))
        {line.number, stored.id}
      end)

    %{offer: offer, line_ids_by_number: ids}
  end

  defp offer_attrs(%{vat_basis: :inclusive, vendor: vendor, minimum_spend: nil}) do
    %{"vendor_name" => vendor}
  end

  defp offer_attrs(%{vat_basis: :exclusive} = given) do
    %{
      "vendor_name" => given.vendor,
      "vat_basis" => "exclusive",
      "vat_rate_input" => VatRate.format(bp(given.default_vat_rate)),
      "minimum_spend_input" => minimum_spend_input(given.minimum_spend)
    }
  end

  defp minimum_spend_input(nil), do: ""

  # Only a whole-euro minimum spend has an input form that is not a formatted money
  # string; `Decimal.to_integer/1` raises for any other.
  defp minimum_spend_input(%Money{currency: :EUR, amount: amount}),
    do: amount |> Decimal.to_integer() |> Integer.to_string()

  # One transcribed line as context attrs, typed values only (DR-18, DR-46).
  defp line_attrs(line, services, dinner) do
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
    |> Map.merge(if line.event, do: %{"event_id" => dinner.id}, else: %{})
  end
end
