defmodule WeddingPlanner.Valuation.BudgetBreakdowns do
  @moduledoc """
  The two `BUD-07` breakdowns besides "by category" (which is
  `WeddingPlanner.Valuation.Budget.forecast/3` itself): **by event** (`by_event/2`,
  `DR-73`) and **per guest** (`per_guest/2`, `DR-74`). Pure (`NFR-41`): both read the
  result of `Budget.overall/3` — and, for per guest, the headcount of the same snapshot —
  and never recompute `BUD-03`. Everything a row is built from is already in that result:
  `categories[].confirmed_offers[].{source, breakdown, forecast}`,
  `planning_pick.breakdown`, `fallback_winner`, `target` and `unlinked_invoices`.

  Arithmetic goes only through `WeddingPlanner.Money` (`NFR-12`); nothing rounds
  (`NFR-14`).

  ## By event (`by_event/2`, `DR-73`)

  The overall **forecast** is attributed, per category, by what `BUD-03` counted:

    * **branch `:confirmed`**, per confirmed offer (in `confirmed_offers` order):
        * `source: :committed` — its `breakdown` lines, in order: a **valid per-person
          line** → its event's row at the line total; a **flat line** → General at the
          line total; an **invalid line** (`XC-42`) contributes nothing; then, iff the
          minimum spend applied (`CST-32`), the uplift `total − line_sum` → General;
        * `source: :invoiced` / `:invoicing_complete` — the offer's whole forecast →
          General (the figure is an invoiced total, not its lines);
    * then, still under `:confirmed`, every unlinked invoice → General;
    * **no confirmed offer** — `fallback_winner: :base`: the planning pick's `breakdown`
      by the same line rule (`:planning_pick`), the target → General (`:target`), nothing
      for `:no_target` (its base is €0); `fallback_winner: :unlinked_invoices`: every
      unlinked invoice → General, and the base contributes nothing.

  An **ad hoc** per-person line goes to its event like a service line (`DR-73`, W12 Q3:
  `BUD-07` lists "per-person lines" under their event and "ad hoc lines" under General;
  an ad hoc line with a per-person basis is read as per-person). That one decision is
  isolated in `ad_hoc_per_person_row/1`; the literal reading is a one-clause change
  there.

  **Rows**: one per event of `snapshot.events`, in that order (`EVT-04`), present even at
  €0, then General. Σ row amounts == the overall forecast **exactly** (property-tested),
  because every category contributes exactly the parts its forecast was summed from.

  Each row is `%{event: event | :general, amount: amount, formula: formula,
  by_category: [%{category: category, amount: amount}]}` — `by_category` lists only the
  categories whose part of the row is non-zero, in category order.

  ### Row formula (`BUD-08`, `NFR-32`)

  `%Formula{label: event.name | "General", steps: steps, total: {:money, amount}}`. The
  steps, exactly, in order (`cat` is the category's `name`, `vendor` the offer's
  `vendor_name`):

    1. iff any contribution of the row comes from a per-person line: `"Headcount preset"`
       → `{:preset, preset.name}` (`HC-08`; the same step `Offer.total/4` uses);
    2. one step per contribution, in category order, then offer order, then line order:
        * a line: `[cat, " — ", vendor, " — " | line label]` → `{:money, line total}`,
          where the line label is the line's `name` for a flat line and, for a
          per-person line, the segments of `WeddingPlanner.Valuation.Offer`'s extend step
          (`DR-50`) — `[name, " — ", {:count, count}, " <noun> at <event name> × ",
          {:money, amount}]`, or with an included quantity `[name, " — (", {:count,
          count}, " <noun> at <event name> − ", {:count, included}, " included) × ",
          {:money, amount}]`. `Offer` keeps that label private, so the same segments are
          rebuilt here from the `line_result` fields (`name`, `count`, `included`, the
          line's `basis`, `included_quantity` and `amount`, `event.name`). The value is the
          **line total** — after the minimum charge and VAT — so it may differ from the
          product the label shows;
        * a minimum-spend uplift: `[cat, " — ", vendor, " — minimum spend applied"]` →
          `{:money, total − line_sum}`;
        * an invoiced offer forecast: `[cat, " — ", vendor, " — invoiced total"]` →
          `{:money, offer forecast}`;
        * a target: `[cat, " — target"]` → `{:money, target}`;
        * an unlinked invoice: `[cat, " — invoice ", invoice label]` →
          `{:money, invoice total}`.

  A row without contributions has no steps and total €0.

  ## Per guest (`per_guest/2`, `DR-74`)

  `n` = `WeddingPlanner.Valuation.Headcount.evaluate(snapshot, overall.preset,
  :all_events).total` — `HC-03`'s distinct persons counted for at least one event under
  the preset `overall` was computed with (a person counted for three events contributes
  1). Per guest = forecast ÷ `n` through `WeddingPlanner.Money.divide/2`, unrounded,
  overall and per category (in category order); `:no_guests` when `n` is 0.

  A figure is `{:ok, %Formula{label: "Per guest", steps: steps, total: {:money,
  forecast ÷ n}}}` with exactly these steps: `"Headcount preset"` → `{:preset, name}`
  (always — the divisor depends on it, `HC-08`), `"Forecast"` → `{:money, forecast}`
  (overall, or the category's), `"Distinct persons counted (all events)"` →
  `{:count, n}`.
  """

  alias WeddingPlanner.Categories.Category
  alias WeddingPlanner.Events.Event
  alias WeddingPlanner.Offers.OfferLine
  alias WeddingPlanner.Valuation.Budget
  alias WeddingPlanner.Valuation.Formula
  alias WeddingPlanner.Valuation.Formula.Step
  alias WeddingPlanner.Valuation.Headcount
  alias WeddingPlanner.Valuation.Preset
  alias WeddingPlanner.Valuation.Snapshot

  @typedoc """
  One row of the by-event breakdown (`DR-73`): an event of `snapshot.events` or
  `:general`, its amount, its formula (label: the event's name / `"General"`) and the
  non-zero parts per category, in category order.
  """
  @type event_row :: %{
          event: Event.t() | :general,
          amount: Money.t(),
          formula: Formula.t(),
          by_category: [%{category: Category.t(), amount: Money.t()}]
        }

  @typedoc "A per-guest figure (`DR-74`): its formula, or `:no_guests` when nobody is counted."
  @type per_guest_figure :: {:ok, Formula.t()} | :no_guests

  @typedoc """
  The per-guest breakdown (`DR-74`): the preset it was computed under (`HC-08`), the
  distinct persons counted across all events (`HC-03`), the overall figure and one figure
  per category (in category order).
  """
  @type per_guest :: %{
          preset: Preset.t(),
          persons: non_neg_integer(),
          overall: per_guest_figure(),
          categories: [%{category: Category.t(), figure: per_guest_figure()}]
        }

  # One attributed part of a category's forecast: which row, how much, its formula step,
  # and whether it came from a per-person line (for the row's preset step).
  @typep contribution :: %{
           row: {:event, Event.t()} | :general,
           category: Category.t(),
           amount: Money.t(),
           step: Step.t(),
           per_person: boolean()
         }

  @doc """
  The overall forecast of `overall` (a `Budget.overall/3` result for `snapshot`) split
  into one row per event of `snapshot.events`, in that order, then General — adding up to
  the forecast exactly. See the moduledoc for the attribution and the formula steps.
  """
  @spec by_event(Snapshot.t(), Budget.overall()) :: [event_row()]
  def by_event(%Snapshot{} = snapshot, %{preset: %Preset{} = preset, categories: categories}) do
    contributions = Enum.flat_map(categories, &category_contributions/1)

    event_rows =
      Enum.map(snapshot.events, fn %Event{id: id} = event ->
        mine = Enum.filter(contributions, &match?(%{row: {:event, %Event{id: ^id}}}, &1))
        row(event, event.name, mine, categories, preset)
      end)

    general = Enum.filter(contributions, &(&1.row == :general))
    event_rows ++ [row(:general, "General", general, categories, preset)]
  end

  @doc """
  The forecast of `overall` (a `Budget.overall/3` result for `snapshot`) per distinct
  person counted across all events under `overall.preset` (`HC-03`), overall and per
  category; `:no_guests` when nobody is counted. See the moduledoc for the formula.
  """
  @spec per_guest(Snapshot.t(), Budget.overall()) :: per_guest()
  def per_guest(%Snapshot{} = snapshot, %{preset: %Preset{} = preset} = overall) do
    %{total: persons} = Headcount.evaluate(snapshot, preset, :all_events)

    %{
      preset: preset,
      persons: persons,
      overall: per_guest_figure(money(overall.forecast), persons, preset),
      categories:
        Enum.map(overall.categories, fn layers ->
          %{
            category: layers.category,
            figure: per_guest_figure(money(layers.forecast), persons, preset)
          }
        end)
    }
  end

  # -- by event: one category ------------------------------------------------------------------

  @spec category_contributions(Budget.category_layers()) :: [contribution()]
  defp category_contributions(%{branch: :confirmed, category: category} = layers) do
    Enum.flat_map(layers.confirmed_offers, &offer_contributions(category, &1)) ++
      Enum.map(layers.unlinked_invoices, &invoice_contribution(category, &1))
  end

  defp category_contributions(%{fallback_winner: :unlinked_invoices, category: category} = l),
    do: Enum.map(l.unlinked_invoices, &invoice_contribution(category, &1))

  defp category_contributions(%{branch: :planning_pick, planning_pick: pick} = layers),
    do: breakdown_contributions(layers.category, pick.offer.vendor_name, pick.breakdown)

  defp category_contributions(%{branch: :target, category: category, target: target}) do
    [general(category, [category.name, " — target"], target)]
  end

  defp category_contributions(%{branch: :no_target}), do: []

  defp offer_contributions(category, %{source: :committed, offer: offer, breakdown: breakdown}),
    do: breakdown_contributions(category, offer.vendor_name, breakdown)

  defp offer_contributions(category, %{offer: offer, forecast: forecast}) do
    [general(category, [category.name, " — ", offer.vendor_name, " — invoiced total"], forecast)]
  end

  defp invoice_contribution(category, %{invoice: invoice, total: total}),
    do: general(category, [category.name, " — invoice ", invoice.label], total)

  # An offer's breakdown by its lines (`CST-36`), then the minimum-spend uplift (`CST-32`).
  defp breakdown_contributions(category, vendor, breakdown) do
    lines = Enum.flat_map(breakdown.lines, &line_contribution(category, vendor, &1))

    uplift =
      if breakdown.minimum_spend_applied do
        amount = WeddingPlanner.Money.subtract(breakdown.total, breakdown.line_sum)
        [general(category, [category.name, " — ", vendor, " — minimum spend applied"], amount)]
      else
        []
      end

    lines ++ uplift
  end

  defp line_contribution(category, vendor, line_result) do
    case line_row(line_result) do
      :none ->
        []

      row ->
        [
          %{
            row: row,
            category: category,
            amount: line_result.total,
            step: %Step{
              label: [category.name, " — ", vendor, " — " | line_label(line_result)],
              value: {:money, line_result.total}
            },
            per_person: OfferLine.per_person?(line_result.line.basis)
          }
        ]
    end
  end

  # Which row a counted line of a `breakdown` goes to (`BUD-07`, `DR-73`).
  defp line_row(%{invalid: true}), do: :none
  defp line_row(%{line: %OfferLine{basis: :flat}}), do: :general
  defp line_row(%{line: %OfferLine{service_id: nil}} = result), do: ad_hoc_per_person_row(result)
  defp line_row(%{event: %Event{} = event}), do: {:event, event}

  # DR-73 (W12 Q3): an ad hoc line with a per-person basis goes to its event, like a
  # service line — the reading that keeps an event's headcount-driven cost on that event.
  # The literal reading of BUD-07 ("ad hoc lines … General") is this clause returning
  # `:general`; nothing else changes.
  defp ad_hoc_per_person_row(%{event: %Event{} = event}), do: {:event, event}

  # The line's label segments: its name (flat) or `Offer`'s extend-step segments (DR-50),
  # rebuilt from the line_result because `Offer` keeps that label private.
  defp line_label(%{line: %OfferLine{basis: :flat}, name: name}), do: [name]

  defp line_label(%{line: %OfferLine{included_quantity: nil} = line} = result) do
    [
      result.name,
      " — ",
      {:count, result.count},
      " #{noun(line.basis, result.count)} at #{result.event.name} × ",
      {:money, line.amount}
    ]
  end

  defp line_label(%{line: line} = result) do
    [
      result.name,
      " — (",
      {:count, result.count},
      " #{noun(line.basis, result.count)} at #{result.event.name} − ",
      {:count, result.included},
      " included) × ",
      {:money, line.amount}
    ]
  end

  defp noun(:per_adult, 1), do: "adult"
  defp noun(:per_adult, _count), do: "adults"
  defp noun(:per_child, 1), do: "child"
  defp noun(:per_child, _count), do: "children"
  defp noun(:per_attendee, 1), do: "attendee"
  defp noun(:per_attendee, _count), do: "attendees"

  defp general(category, label, amount) do
    %{
      row: :general,
      category: category,
      amount: amount,
      step: %Step{label: label, value: {:money, amount}},
      per_person: false
    }
  end

  # -- by event: one row -----------------------------------------------------------------------

  defp row(event, label, contributions, categories, preset) do
    amount = sum(Enum.map(contributions, & &1.amount))

    preset_steps =
      if Enum.any?(contributions, & &1.per_person),
        do: [%Step{label: "Headcount preset", value: {:preset, preset.name}}],
        else: []

    by_category =
      Enum.flat_map(categories, fn %{category: %Category{id: id} = category} ->
        part =
          contributions
          |> Enum.filter(&(&1.category.id == id))
          |> Enum.map(& &1.amount)
          |> sum()

        case WeddingPlanner.Money.compare(part, zero()) do
          :eq -> []
          _ -> [%{category: category, amount: part}]
        end
      end)

    %{
      event: event,
      amount: amount,
      formula: %Formula{
        label: label,
        steps: preset_steps ++ Enum.map(contributions, & &1.step),
        total: {:money, amount}
      },
      by_category: by_category
    }
  end

  # -- per guest -------------------------------------------------------------------------------

  defp per_guest_figure(_forecast, 0, _preset), do: :no_guests

  defp per_guest_figure(%Money{} = forecast, persons, %Preset{name: name}) do
    {:ok,
     %Formula{
       label: "Per guest",
       steps: [
         %Step{label: "Headcount preset", value: {:preset, name}},
         %Step{label: "Forecast", value: {:money, forecast}},
         %Step{label: "Distinct persons counted (all events)", value: {:count, persons}}
       ],
       total: {:money, WeddingPlanner.Money.divide(forecast, persons)}
     }}
  end

  # -- helpers ---------------------------------------------------------------------------------

  defp money(%Formula{total: {:money, %Money{} = money}}), do: money

  defp sum(amounts), do: WeddingPlanner.Money.sum(amounts)

  defp zero, do: WeddingPlanner.Money.new(0)
end
