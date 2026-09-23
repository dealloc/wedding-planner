defmodule WeddingPlanner.NormativeSnapshots do
  @moduledoc """
  The frozen normative offers of `WeddingPlanner.NormativeExamples` (Venue A, Venue B,
  Caterer C) as **real structs** in an in-memory `WeddingPlanner.Valuation.Snapshot` —
  `Category`, `Service`, `Event`, `Offer` and `OfferLine`, no database. Test support only;
  the cost engine's tests (slice C3) evaluate these.

  Everything is taken from `NormativeExamples`' maps, never retyped: amounts are the
  fixture's own `%Money{}` values (built from integers/`Decimal`s, `DR-18`), rates its
  `Decimal` fractions turned into basis points (`0.21` → `2100`).
  `WeddingPlanner.NormativeSnapshotsTest` checks the structs against the maps field by
  field (tagged `:normative_fixture`).

  ## What `snapshot/1` returns

      %{snapshot: %Snapshot{}, offer: %Offer{}, services: %{name => %Service{}},
        event: %Event{}, lines: %{number => %OfferLine{}}}

  The snapshot holds exactly one `Dinner` event, the offer's category, its services in
  the docs' order (`sort_order` 0…n) with the docs' priorities, the offer, and one
  `OfferLine` per transcribed line. Ids are explicit: a line's `id` is its docs `number`
  (so ad hoc lines keep the docs' relative order), services are numbered `101…` (Venue)
  and `201…` (Catering). `enabled` is `false` on every line; `overrides` is empty (see
  `with_overrides/2`).

  ## Venue B is test construction, not normative data

  The docs give only Venue B's Catering situation (no Catering line, or a *not offered*
  one — O3); no other line of Venue B is stated. To give it a total at all, its
  non-Catering lines are **borrowed from Venue A**: Venue A's lines **without** lines 3
  and 4 (the two Catering lines), same numbers and ids, on Venue B's offer. The
  `:not_offered_line` variant adds one Catering line in state `:not_offered` with id/number
  `9`. This lets the cost engine show O3's "total excludes catering" as
  `total(B) = total(A) − catering lines`. None of this is in `docs/`.
  """

  alias WeddingPlanner.Categories.Category
  alias WeddingPlanner.Categories.Service
  alias WeddingPlanner.Events.Event
  alias WeddingPlanner.NormativeExamples, as: NE
  alias WeddingPlanner.Offers.Offer
  alias WeddingPlanner.Offers.OfferLine
  alias WeddingPlanner.Valuation.Snapshot

  @event_id 1
  @venue_category_id 1
  @catering_category_id 2

  @typedoc "What `snapshot/1` builds."
  @type built :: %{
          snapshot: Snapshot.t(),
          offer: Offer.t(),
          services: %{String.t() => Service.t()},
          event: Event.t(),
          lines: %{pos_integer() => OfferLine.t()}
        }

  @typedoc "Which normative offer to build."
  @type which ::
          :venue_a | {:venue_b, :no_line} | {:venue_b, :not_offered_line} | :caterer_c

  @doc "The id Venue B's `:not_offered_line` variant gives its Catering line."
  @spec venue_b_not_offered_line_id() :: pos_integer()
  def venue_b_not_offered_line_id, do: 9

  @doc "Builds the snapshot of one normative offer (see the moduledoc)."
  @spec snapshot(which()) :: built()
  def snapshot(:venue_a) do
    offer = NE.venue_a()
    build(NE.venue_category(), @venue_category_id, 101, offer, 1, offer.lines)
  end

  def snapshot({:venue_b, variant}) when variant in [:no_line, :not_offered_line] do
    venue_a = NE.venue_a()
    %{vendor: vendor, catering: variants} = NE.venue_b()
    # Both variants are the fixture's own (O3); fail loudly if it ever stops listing one.
    true = variant in variants

    borrowed = Enum.reject(venue_a.lines, &(&1.service == "Catering"))

    extra =
      case variant do
        :no_line ->
          []

        :not_offered_line ->
          [
            %{
              number: venue_b_not_offered_line_id(),
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

    offer = %{venue_a | vendor: vendor}
    build(NE.venue_category(), @venue_category_id, 101, offer, 2, borrowed ++ extra)
  end

  def snapshot(:caterer_c) do
    offer = NE.caterer_c()
    build(NE.catering_category(), @catering_category_id, 201, offer, 3, offer.lines)
  end

  @doc """
  Adds override rows (`DR-49`: `offer_id`, `service_id`, `wanted`) for the built offer,
  one per `{service_name, wanted}`, appended in order.
  """
  @spec with_overrides(built(), [{String.t(), boolean()}]) :: built()
  def with_overrides(%{snapshot: snapshot, offer: offer, services: services} = built, pairs) do
    rows =
      for {name, wanted} <- pairs do
        %{offer_id: offer.id, service_id: Map.fetch!(services, name).id, wanted: wanted}
      end

    %{built | snapshot: %{snapshot | overrides: snapshot.overrides ++ rows}}
  end

  @doc "Puts (inserts or replaces by id) `line` on the built offer."
  @spec put_line(built(), OfferLine.t()) :: built()
  def put_line(%{snapshot: snapshot, offer: offer, lines: lines} = built, %OfferLine{} = line) do
    line = %{line | offer_id: offer.id}

    %{
      built
      | snapshot: Snapshot.apply(snapshot, {:put, :offer_lines, line}),
        lines: Map.put(lines, line.id, line)
    }
  end

  # -- building -----------------------------------------------------------------------------

  defp build(category_map, category_id, first_service_id, offer_map, offer_id, line_maps) do
    event = %Event{id: @event_id, name: "Dinner", sort_order: 0}
    category = %Category{id: category_id, name: category_map.name, sort_order: 0}

    services =
      category_map.services
      |> Enum.with_index()
      |> Enum.map(fn {%{name: name, priority: priority}, index} ->
        %Service{
          id: first_service_id + index,
          category_id: category_id,
          name: name,
          wanted_priority: priority,
          sort_order: index
        }
      end)

    services_by_name = Map.new(services, &{&1.name, &1})

    offer = %Offer{
      id: offer_id,
      category_id: category_id,
      vendor_name: offer_map.vendor,
      status: :considering,
      vat_basis: offer_map.vat_basis,
      vat_rate_bp: basis_points(offer_map.default_vat_rate),
      minimum_spend: offer_map.minimum_spend
    }

    lines = Enum.map(line_maps, &offer_line(&1, offer, services_by_name, event))

    %{
      snapshot: %Snapshot{
        events: [event],
        categories: [category],
        services: services,
        offers: [offer],
        offer_lines: lines
      },
      offer: offer,
      services: services_by_name,
      event: event,
      lines: Map.new(lines, &{&1.id, &1})
    }
  end

  defp offer_line(map, offer, services_by_name, event) do
    {service_id, label} =
      case map.service do
        nil -> {nil, map.label}
        name -> {Map.fetch!(services_by_name, name).id, nil}
      end

    %OfferLine{
      id: map.number,
      offer_id: offer.id,
      service_id: service_id,
      label: label,
      state: map.state,
      basis: map.basis,
      event_id: event_id(map.event, event),
      amount: map.amount,
      included_quantity: map.included,
      minimum_charge: map.minimum_charge,
      vat_rate_bp: basis_points(map.vat_rate),
      enabled: false
    }
  end

  defp event_id(nil, _event), do: nil
  defp event_id(name, %Event{name: name, id: id}), do: id

  defp basis_points(nil), do: nil

  defp basis_points(%Decimal{} = fraction),
    do: fraction |> Decimal.mult(10_000) |> Decimal.to_integer()
end
