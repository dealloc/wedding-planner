defmodule WeddingPlanner.NormativeMatrix do
  @moduledoc """
  The Venue comparison of `docs/modules/offers-and-comparison.md`'s worked example as one
  in-memory `WeddingPlanner.Valuation.Snapshot`: category **Venue** with **Venue A** and
  **Venue B** as two offers (two matrix columns), the shared Dinner guest list as real
  `Person`/`Invitation` structs, and the three default presets stored-style. Test support
  only; `WeddingPlanner.Valuation.ComparisonTest` evaluates it through
  `WeddingPlanner.Valuation.Comparison.build/4` with **no** headcount seam.

  ## Built from the frozen fixture, never retyped

  Both offers come from `WeddingPlanner.NormativeSnapshots.snapshot/1`, which builds them
  from `WeddingPlanner.NormativeExamples`' maps (Venue B's non-Catering lines are borrowed
  from Venue A there — test construction, see that module). `NormativeSnapshots` gives
  Venue B **Venue A's line ids**, so the two cannot share one snapshot as built: here
  Venue B's lines are re-numbered to `100 + number` (`venue_b_line_id/1`). Everything
  else — the category (id 1), its services (`101…105`, the docs' order and priorities),
  the Dinner event (id 1), the offers (ids 1 and 2) — is taken as built.
  `WeddingPlanner.Valuation.ComparisonTest` self-checks the result against the maps
  (tagged `:normative_fixture`).

  ## The guests

  The shared Dinner fixture of `docs/07-normative-examples.md`, in the same construction
  as `WeddingPlanner.NormativeGuests.shared_dinner!/2` (task 24, `DR-26` D8) but in
  memory: 60 *certain* adults, 4 *certain* children, 12 *likely* adults, 2 *likely*
  children, want tier *yes*, all *invited* to Dinner, no +1, no group. So Minimum = 60 + 4
  and Likely = 72 + 6. Its Maximum (72 + 6, there being no *uncertain* person) is a
  by-product, not a normative figure.

  ## The presets

  `WeddingPlanner.Valuation.Preset.defaults/0` with ids 1–3, as the loader would carry
  the seeded rows (`DR-47`), in `snapshot.headcount_presets` and by name in `presets`.
  """

  alias WeddingPlanner.Guests.Person
  alias WeddingPlanner.Invitations.Invitation
  alias WeddingPlanner.NormativeSnapshots
  alias WeddingPlanner.Offers.OfferLine
  alias WeddingPlanner.Valuation.Preset
  alias WeddingPlanner.Valuation.Snapshot

  @venue_b_line_offset 100

  # {count, certainty, age} — the shared Dinner fixture's construction (DR-26 D8).
  @guest_roles [
    {60, :certain, :adult},
    {4, :certain, :child},
    {12, :likely, :adult},
    {2, :likely, :child}
  ]

  @typedoc "Which Venue B variant (O3) to put next to Venue A."
  @type venue_b_variant :: :no_line | :not_offered_line

  @typedoc "An offer of the matrix."
  @type which :: :venue_a | :venue_b

  @typedoc "What `snapshot/1` builds."
  @type built :: %{
          snapshot: Snapshot.t(),
          category_id: pos_integer(),
          offers: %{which() => WeddingPlanner.Offers.Offer.t()},
          services: %{String.t() => WeddingPlanner.Categories.Service.t()},
          event: WeddingPlanner.Events.Event.t(),
          lines: %{which() => %{pos_integer() => OfferLine.t()}},
          presets: %{String.t() => Preset.t()}
        }

  @doc "The id Venue B's line with docs `number` gets in the matrix snapshot."
  @spec venue_b_line_id(pos_integer()) :: pos_integer()
  def venue_b_line_id(number), do: @venue_b_line_offset + number

  @doc "Builds the two-column Venue snapshot (see the moduledoc)."
  @spec snapshot(venue_b_variant()) :: built()
  def snapshot(venue_b_variant \\ :no_line) do
    a = NormativeSnapshots.snapshot(:venue_a)
    b = NormativeSnapshots.snapshot({:venue_b, venue_b_variant})

    # Same category, services and event on both sides (the matrix is one category).
    true = a.snapshot.categories == b.snapshot.categories
    true = a.snapshot.services == b.snapshot.services
    true = a.snapshot.events == b.snapshot.events

    b_lines = Map.new(b.lines, fn {number, line} -> {number, renumber(line)} end)

    {persons, invitations} = guests(a.event)
    presets = presets()

    snapshot = %Snapshot{
      a.snapshot
      | offers: a.snapshot.offers ++ b.snapshot.offers,
        offer_lines: a.snapshot.offer_lines ++ Enum.map(b.snapshot.offer_lines, &renumber/1),
        persons: persons,
        invitations: invitations,
        headcount_presets: presets
    }

    %{
      snapshot: snapshot,
      category_id: a.offer.category_id,
      offers: %{venue_a: a.offer, venue_b: b.offer},
      services: a.services,
      event: a.event,
      lines: %{venue_a: a.lines, venue_b: b_lines},
      presets: Map.new(presets, &{&1.name, &1})
    }
  end

  @doc """
  Adds override rows (`DR-49`: `offer_id`, `service_id`, `wanted`) for offer `which`, one
  per `{service_name, wanted}`, appended in order.
  """
  @spec with_overrides(built(), which(), [{String.t(), boolean()}]) :: built()
  def with_overrides(%{snapshot: snapshot} = built, which, pairs) do
    offer = Map.fetch!(built.offers, which)

    rows =
      for {name, wanted} <- pairs do
        %{offer_id: offer.id, service_id: Map.fetch!(built.services, name).id, wanted: wanted}
      end

    %{built | snapshot: %{snapshot | overrides: snapshot.overrides ++ rows}}
  end

  @doc "Puts (inserts or replaces by id) `line` on offer `which`."
  @spec put_line(built(), which(), OfferLine.t()) :: built()
  def put_line(%{snapshot: snapshot} = built, which, %OfferLine{} = line) do
    line = %{line | offer_id: Map.fetch!(built.offers, which).id}

    %{
      built
      | snapshot: Snapshot.apply(snapshot, {:put, :offer_lines, line}),
        lines: Map.update!(built.lines, which, &Map.put(&1, line.id, line))
    }
  end

  @doc "Replaces offer `which` (same id) with `fun.(offer)`."
  @spec update_offer(built(), which(), (WeddingPlanner.Offers.Offer.t() ->
                                          WeddingPlanner.Offers.Offer.t())) :: built()
  def update_offer(%{snapshot: snapshot} = built, which, fun) do
    offer = built.offers |> Map.fetch!(which) |> fun.()

    %{
      built
      | snapshot: Snapshot.apply(snapshot, {:put, :offers, offer}),
        offers: Map.put(built.offers, which, offer)
    }
  end

  # -- building -------------------------------------------------------------------------------

  defp renumber(%OfferLine{id: id} = line), do: %{line | id: venue_b_line_id(id)}

  defp guests(event) do
    persons =
      @guest_roles
      |> Enum.flat_map(fn {count, certainty, age} ->
        List.duplicate({certainty, age}, count)
      end)
      |> Enum.with_index(1)
      |> Enum.map(fn {{certainty, age}, id} ->
        %Person{
          id: id,
          first_name: "Shared guest",
          last_name: Integer.to_string(id),
          age_category: age,
          certainty: certainty,
          want_tier: :yes
        }
      end)

    invitations =
      for person <- persons do
        %Invitation{id: person.id, person_id: person.id, event_id: event.id, status: :invited}
      end

    {persons, invitations}
  end

  defp presets do
    Preset.defaults()
    |> Enum.with_index(1)
    |> Enum.map(fn {preset, id} -> %{preset | id: id} end)
  end
end
