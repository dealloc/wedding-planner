defmodule WeddingPlanner.NormativeExamples do
  @moduledoc """
  The normative cost and budget examples of `docs/07-normative-examples.md` (O1–O6,
  B1–B4), **frozen once** as test data: their inputs, transcribed from
  `docs/modules/offers-and-comparison.md` and `docs/modules/invoices-and-budget.md`, and
  their expected results. Test support only (`elixirc_paths(:test)`).

  Every figure here was re-derived by hand in the documentation audit, and again when it
  was frozen; `WeddingPlanner.NormativeExamplesTest` re-derives them a third time on
  every run. They are the test oracle for the cost engine (slice C3) and the budget
  engine (slice B3): a figure that is wrong here fails **green**, because every
  downstream test would agree with it. Change one only when `docs/` changes.

  ## Transcribed test data, not a schema

  The maps below mirror the docs' tables column for column. They are **not** a model of
  categories, offers, lines or invoices: slices C2/C3 map this data into their own
  structs and MUST NOT shape their schemas after it. Nothing here is a Person,
  Invitation, Offer or Offer line struct; the real-data guest fixture (actual persons
  and invitations that evaluate to the shared headcount) is a separate task.

  ## Money (`DR-18`, `DR-17`)

  Every amount is built with `WeddingPlanner.Money.new/1` from an integer or a
  `Decimal` — never from a string, which under the `nl-BE` locale is silently 100× wrong.
  Do not paste an inspected `%Money{}` (`Money.new(:EUR, "7641.50")`) back into code; it
  does not round-trip. The docs write money in English prose (`€7,641.50`); the app
  renders `nl-BE` (`€ 7.641,50`, non-breaking space). The *values* are what is frozen.
  VAT rates are `Decimal` fractions (`Decimal.new("0.12")`). Amounts are VAT inclusive
  unless the offer's `vat_basis` is `:exclusive` (`docs/README.md`, `CST-33`).

  ## The shared headcount and the seam

  `shared_headcount/0` is the doc's shared fixture: event **Dinner**, preset **Likely**
  72 adults + 6 children = 78, preset **Minimum** 60 adults + 4 children = 64.
  `fixed_headcount/0` turns it into a function for the engines' `headcount:` test seam
  (`WeddingPlanner.Valuation.Offer.total/4`, `WeddingPlanner.Valuation.Budget.forecast/3`).
  The docs give **no** Maximum figure for this fixture, so none is invented: the
  function raises for any other preset or event, and a test that needs a range supplies
  its own counts.

  ## Tagging convention (for the coverage audit)

    * A test that implements a normative example **through the real engine or
      context** is tagged `@tag example: "<id>"` with the bare example id, e.g.
      `@tag example: "O4"`. `mix test --only example` then lists every implemented
      example, and the final coverage audit checks the ids against
      `docs/07-normative-examples.md` mechanically.
    * The fixture's own transcription self-checks are tagged `:normative_fixture`
      instead, and **never** carry an `example:` tag: a check that the transcription
      adds up is not the example being implemented, and must not be counted as such.

  ## Shapes

  Line maps (`venue_a/0`, `caterer_c/0`) carry: `number`, `label`, `service` (a service
  name, or `nil` for an ad hoc line), `state`, `basis` (`nil` where the doc gives none),
  `event`, `amount`, `included`, `minimum_charge`, `vat_rate` (`nil` means the offer's
  default rate), and `result` — the doc's stated per-line result, keyed by preset name,
  present **only** for the presets the doc states it under. A result is a `%Money{}`, or
  an atom for a line the doc says contributes no priced amount (`:excluded_not_wanted`,
  `:ask_the_vendor`). Caterer C's results are `%{subtotal: excl, total: incl}`, the doc's
  two columns.

  Priorities are `:must_have | :nice_to_have | :not_wanted` (`CST-03`); states
  `:included | :optional | :mandatory | :not_offered | :unknown` (`CST-21`); bases
  `:flat | :per_adult | :per_child | :per_attendee` (`CST-30`).
  """

  alias WeddingPlanner.Events.Event
  alias WeddingPlanner.Valuation.Headcount
  alias WeddingPlanner.Valuation.Offer
  alias WeddingPlanner.Valuation.Preset

  @example_ids ~w(O1 O2 O3 O4 O5 O6 B1 B2 B3 B4)

  # --- shared fixture -------------------------------------------------------------------

  @doc "The doc's shared headcount: event name → preset name → counts."
  @spec shared_headcount() :: %{String.t() => %{String.t() => Headcount.counts()}}
  def shared_headcount do
    %{
      "Dinner" => %{
        "Likely" => %{adults: 72, children: 6, total: 78},
        "Minimum" => %{adults: 60, children: 4, total: 64}
      }
    }
  end

  @doc """
  A `t:WeddingPlanner.Valuation.Offer.headcount_fun/0` for the engines' `headcount:`
  test seam: looks the event's and preset's names up in `shared_headcount/0` and ignores
  the snapshot. Raises `ArgumentError` for any event, preset or `:all_events` the docs
  give no figure for — it never invents one.
  """
  @spec fixed_headcount() :: Offer.headcount_fun()
  def fixed_headcount do
    fn _snapshot, %Preset{name: preset_name}, event ->
      event_name = event_name(event)

      case get_in(shared_headcount(), [event_name, preset_name]) do
        %{} = counts ->
          counts

        nil ->
          raise ArgumentError,
                "WeddingPlanner.NormativeExamples.fixed_headcount/0 has no figure for " <>
                  "event #{inspect(event_name)} under preset #{inspect(preset_name)}: " <>
                  "docs/07-normative-examples.md fixes only Dinner under Likely and " <>
                  "Minimum. A test that needs other counts must supply its own headcount " <>
                  "function."
      end
    end
  end

  defp event_name(%Event{couple_attends: false, name: name}), do: name
  defp event_name(other), do: other

  # --- inputs ---------------------------------------------------------------------------

  @doc "Category **Venue** and its services' wanted priorities (offers-and-comparison.md)."
  def venue_category do
    %{
      name: "Venue",
      services: [
        %{name: "Seating", priority: :nice_to_have},
        %{name: "Catering", priority: :must_have},
        %{name: "Sound", priority: :nice_to_have},
        %{name: "Garden ceremony", priority: :not_wanted},
        %{name: "Late-night snack", priority: :nice_to_have}
      ]
    }
  end

  @doc "Category **Catering** and its services' wanted priorities (the Caterer C example)."
  def catering_category do
    %{
      name: "Catering",
      services: [
        %{name: "Dinner catering", priority: :must_have},
        %{name: "Drinks", priority: :nice_to_have}
      ]
    }
  end

  @doc "Category **Attire** of B3: no offers, target €2,500."
  def attire_category do
    %{name: "Attire", target: eur(2500), services: [], offers: []}
  end

  @doc """
  **Venue A** (O1, O2): all VAT inclusive, no minimum spend. Results as the doc states
  them; its Minimum table lists only lines 1, 2, 3, 4 and 7, so lines 5, 6 and 8 carry
  a Likely result only. Mandatory lines count regardless of the service's wanted
  priority.
  """
  def venue_a do
    %{
      vendor: "Venue A",
      category: "Venue",
      vat_basis: :inclusive,
      default_vat_rate: nil,
      minimum_spend: nil,
      lines: [
        line(1, "Base price", nil, :mandatory, :flat, nil, eur(4000),
          result: %{"Likely" => eur(4000), "Minimum" => eur(4000)}
        ),
        line(2, "Seating", "Seating", :mandatory, :per_attendee, "Dinner", eur(12),
          included: 50,
          result: %{"Likely" => eur(336), "Minimum" => eur(168)}
        ),
        line(3, "Catering", "Catering", :optional, :per_adult, "Dinner", eur(85),
          minimum_charge: eur(6800),
          result: %{"Likely" => eur(6800), "Minimum" => eur(6800)}
        ),
        line(4, "Catering", "Catering", :optional, :per_child, "Dinner", eur(40),
          result: %{"Likely" => eur(240), "Minimum" => eur(160)}
        ),
        line(5, "Sound", "Sound", :included, nil, nil, nil, result: %{"Likely" => eur(0)}),
        line(6, "Garden ceremony", "Garden ceremony", :optional, :flat, nil, eur(500),
          result: %{"Likely" => :excluded_not_wanted}
        ),
        line(7, "Cleaning fee", nil, :mandatory, :flat, nil, eur(350),
          result: %{"Likely" => eur(350), "Minimum" => eur(350)}
        ),
        line(8, "Late-night snack", "Late-night snack", :unknown, nil, nil, nil,
          result: %{"Likely" => :ask_the_vendor}
        )
      ]
    }
  end

  @doc """
  **Venue B** (O3): the doc gives only that it has no Catering line, or a *not offered*
  one. Either variant must produce O3's expectation; no other line is stated.
  """
  def venue_b do
    %{
      vendor: "Venue B",
      category: "Venue",
      catering: [:no_line, :not_offered_line]
    }
  end

  @doc """
  **Caterer C** (O4–O6): VAT exclusive, default rate 21%, minimum spend €7,000 VAT
  inclusive. Lines 1–2 override the rate with 12%; lines 3–4 use the offer default
  (`vat_rate: nil`). Line 4's minimum charge (€200) is excl. VAT, in the offer's basis.
  """
  def caterer_c do
    %{
      vendor: "Caterer C",
      category: "Catering",
      vat_basis: :exclusive,
      default_vat_rate: Decimal.new("0.21"),
      minimum_spend: eur(7000),
      lines: [
        line(1, "Dinner catering", "Dinner catering", :mandatory, :per_adult, "Dinner", eur(60),
          vat_rate: Decimal.new("0.12"),
          result: %{
            "Likely" => %{subtotal: eur(4320), total: eur(Decimal.new("4838.40"))},
            "Minimum" => %{subtotal: eur(3600), total: eur(Decimal.new("4032.00"))}
          }
        ),
        line(2, "Dinner catering", "Dinner catering", :mandatory, :per_child, "Dinner", eur(30),
          vat_rate: Decimal.new("0.12"),
          result: %{
            "Likely" => %{subtotal: eur(180), total: eur(Decimal.new("201.60"))},
            "Minimum" => %{subtotal: eur(120), total: eur(Decimal.new("134.40"))}
          }
        ),
        line(3, "Drinks", "Drinks", :optional, :per_attendee, "Dinner", eur(25),
          result: %{
            "Likely" => %{subtotal: eur(1950), total: eur(Decimal.new("2359.50"))},
            "Minimum" => %{subtotal: eur(1600), total: eur(Decimal.new("1936.00"))}
          }
        ),
        line(4, "Travel", nil, :mandatory, :flat, nil, eur(150),
          minimum_charge: eur(200),
          result: %{
            "Likely" => %{subtotal: eur(200), total: eur(Decimal.new("242.00"))},
            "Minimum" => %{subtotal: eur(200), total: eur(Decimal.new("242.00"))}
          }
        )
      ]
    }
  end

  @doc "Every example id frozen here."
  @spec example_ids() :: [String.t()]
  def example_ids, do: @example_ids

  @doc "The inputs of example `id`, as plain data."
  @spec given(String.t()) :: map()
  def given("O1"), do: %{category: venue_category(), offer: venue_a(), preset: "Likely"}
  def given("O2"), do: %{category: venue_category(), offer: venue_a(), preset: "Minimum"}
  def given("O3"), do: %{category: venue_category(), offer: venue_b()}
  def given("O4"), do: %{category: catering_category(), offer: caterer_c(), preset: "Likely"}
  def given("O5"), do: %{category: catering_category(), offer: caterer_c(), preset: "Minimum"}
  def given("O6"), do: %{category: catering_category(), offer: caterer_c()}

  def given("B1") do
    %{
      category: venue_category(),
      confirmed_offer: venue_a(),
      preset: "Likely",
      committed: eur(11_726),
      invoicing_complete: false,
      invoices: [%{label: "Deposit", amount: eur(3000), paid: true}]
    }
  end

  # The doc does not say whether the final invoice is paid; B2's expectations do not
  # depend on it.
  def given("B2") do
    %{
      given("B1")
      | invoicing_complete: true,
        invoices: [
          %{label: "Deposit", amount: eur(3000), paid: true},
          %{label: "Final invoice", amount: eur(8900), paid: :not_stated}
        ]
    }
  end

  def given("B3"), do: %{category: attire_category()}

  # The doc gives the added household but not its members' certainty or want tier, so
  # which presets it moves is not fixed here — only the figure it must not produce.
  def given("B4") do
    %{
      category: venue_category(),
      offer: venue_a(),
      what_if: %{adds: %{adults: 2, children: 1}, event: "Dinner", status: :invited}
    }
  end

  @doc """
  The expected result of example `id`, as `%Money{}` values (`DR-18`).

  B1/B2's variance is frozen as the doc words it, a magnitude plus a direction
  (`:not_yet_invoiced` / `:above_committed`), not as a signed amount: `BIL-07` does not
  fix a sign convention, and the budget engine's tests should not inherit one from here.
  """
  @spec expected(String.t()) :: map()
  def expected("O1"), do: %{offer: "Venue A", preset: "Likely", total: eur(11_726)}
  def expected("O2"), do: %{offer: "Venue A", preset: "Minimum", total: eur(11_478)}

  def expected("O3") do
    %{
      offer: "Venue B",
      gap: %{service: "Catering", priority: :must_have, marker: :prominent_warning},
      total_excludes_service: "Catering",
      like_for_like: false
    }
  end

  def expected("O4") do
    %{
      offer: "Caterer C",
      preset: "Likely",
      line_sum: eur(Decimal.new("7641.50")),
      minimum_spend_applied: false,
      total: eur(Decimal.new("7641.50"))
    }
  end

  def expected("O5") do
    %{
      offer: "Caterer C",
      preset: "Minimum",
      line_sum: eur(Decimal.new("6344.40")),
      minimum_spend_applied: true,
      total: eur(Decimal.new("7000.00"))
    }
  end

  def expected("O6") do
    %{
      offer: "Caterer C",
      # Both figures are WRONG — a correct engine must never produce either.
      sum_then_one_rate: %{
        preset: "Likely",
        subtotal_sum: eur(6650),
        rate: Decimal.new("0.21"),
        wrong_total: eur(Decimal.new("8046.50")),
        correct_total: eur(Decimal.new("7641.50"))
      },
      minimum_spend_before_vat: %{
        preset: "Minimum",
        subtotal_sum: eur(5520),
        rate: Decimal.new("0.21"),
        wrong_total: eur(8470),
        correct_total: eur(Decimal.new("7000.00"))
      }
    }
  end

  def expected("B1") do
    %{
      category: "Venue",
      preset: "Likely",
      forecast: eur(11_726),
      paid: eur(3000),
      invoiced: eur(3000),
      outstanding: eur(0),
      variance: %{amount: eur(8726), direction: :not_yet_invoiced}
    }
  end

  def expected("B2") do
    %{
      category: "Venue",
      preset: "Likely",
      forecast: eur(11_900),
      variance: %{amount: eur(174), direction: :above_committed}
    }
  end

  def expected("B3"), do: %{category: "Attire", forecast_under_every_preset: eur(2500)}

  def expected("B4") do
    %{
      # 2 × €85 + €40 + 3 × €12 — the per-person-rate delta BUD-21 forbids. The real
      # what-if evaluates the whole forecast twice and MUST NOT produce this figure.
      naive_delta: eur(246)
    }
  end

  # --- helpers --------------------------------------------------------------------------

  defp eur(amount), do: WeddingPlanner.Money.new(amount)

  defp line(number, label, service, state, basis, event, amount, opts) do
    %{
      number: number,
      label: label,
      service: service,
      state: state,
      basis: basis,
      event: event,
      amount: amount,
      included: Keyword.get(opts, :included),
      minimum_charge: Keyword.get(opts, :minimum_charge),
      vat_rate: Keyword.get(opts, :vat_rate),
      result: Keyword.fetch!(opts, :result)
    }
  end
end
