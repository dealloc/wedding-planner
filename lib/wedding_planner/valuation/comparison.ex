defmodule WeddingPlanner.Valuation.Comparison do
  @moduledoc """
  The comparison matrix of one category as a pure view model
  (`docs/modules/offers-and-comparison.md` `CST-50`…`CST-55`; `docs/04-cross-cutting.md`
  `XC-42`; `DR-49`, `DR-56`, `DR-57`, `DR-61`, `DR-64`). Pure (`NFR-41`): everything is
  read from a `WeddingPlanner.Valuation.Snapshot`.

  ## Composed, never re-derived

  Every figure and flag here comes from the C3 engines, so the matrix can never disagree
  with the offer page's Cost card or with the budget (B3):

    * which lines exist, their order and how each takes part in the total —
      `WeddingPlanner.Valuation.Selection.lines/2` and `inclusion/3` (`CST-21`,
      `CST-22`, `DR-41`, `DR-49`);
    * whether a service is effectively wanted for an offer —
      `Selection.effectively_wanted?/3` (`CST-24`);
    * gaps and their severities — `WeddingPlanner.Valuation.Gaps.for_offer/2`
      (`CST-25`, `DR-52`);
    * a column's total — `WeddingPlanner.Valuation.Offer.total/4`, the very formula the
      offer page shows (`CST-34`), **never** a sum of the cells;
    * a counted line's total — its line in `Offer.breakdown/4` under the same preset;
    * a line's validity — `WeddingPlanner.Offers.OfferLine.invalid?/1` (`XC-41`).

  Nothing here counts, prices, rounds or formats: the web layer turns this into strings
  (price summaries such as "€85 / adult · €40 / child", `CST-52`, and money).

  ## Shape (`DR-57`)

    * `columns` — every offer of the category, by `id`, **rejected offers included**
      with `rejected?: true` (`CST-55`: hiding them is the screen's job). Per column: its
      gaps, the tallies by severity (`CST-54`: warnings / markers / unknowns),
      `needs_attention?` — `WeddingPlanner.Valuation.Offer.needs_attention?/2`: the offer
      has **any** invalid line, counted or not (`XC-42`, `DR-84`) —, its total under the
      selected preset, `like_for_like?` (no gaps; example O3's "not like-for-like"), and
      the range (`CST-53`).
    * `bands` — always the three wanted priorities in `CST-51` order (must-have,
      nice-to-have, not wanted), each with its services in the category's service order
      (`CST-02`) and one cell per offer (`CST-50`, `CST-52`).
    * `other_charges` — per offer, its ad hoc lines (`CST-50`'s "other charges" section),
      in `Selection.lines/2` order; every offer of the category has a key.

  Every line of every offer of the category appears exactly once: in its service's cell
  or, for an ad hoc line, in `other_charges`.

  A line's `total` is its `Offer.breakdown/4` total under the selected preset when the
  line is `:counted` (an invalid counted line: the engine's flagged €0), otherwise `nil`
  (`:not_selected`, `:outside_scope`, `:no_charge`); every total is `nil` when no preset
  is selected.

  ## Overrides (`DR-49`, `DR-56`)

  A cell's `override` is the override row for that offer × service, or `nil`. Rows are
  read from `snapshot.overrides` exactly as `Selection` reads them — at most one per
  offer × service is assumed, and should several match the **last** one is taken, as
  `Selection` does. The row **deviates** when its `wanted` differs from what the
  service's priority alone gives: `Selection.effectively_wanted?/3` over the snapshot
  with no override rows at all. The matrix marks only deviating rows.

  ## Confirmed offers (`CST-40`, `CST-43`, `DR-61`, `DR-64`)

  For a **confirmed** offer `Selection` answers from the frozen selection, so its
  inclusions, gaps and total follow with nothing to do here; an optional service line
  outside the frozen selection comes through as `:outside_scope`. Its override rows are
  dormant while it is confirmed, so every one of its cells has `override: nil`. Each
  cell carries `scope`: `:in` when the service is in the offer's confirmed scope
  (`Selection.in_confirmed_scope?/3`), `:out` when it is not — and `nil` for every
  offer that is not confirmed.

  ## Presets (`CST-53`, `DR-54`)

  `build/4` takes the selected preset and the range presets explicitly —
  `WeddingPlanner.Valuation.PresetChoice` resolves them from the stored presets. The
  range is the lower and the higher of the two range presets' totals, ordered with
  `Money.compare!/2` (no arithmetic), so an edit that inverts the two presets still
  reads low–high. Each distinct preset is evaluated once per offer.
  """

  alias WeddingPlanner.Categories.Category
  alias WeddingPlanner.Categories.Service
  alias WeddingPlanner.Offers
  alias WeddingPlanner.Offers.OfferLine
  alias WeddingPlanner.Valuation.Formula
  alias WeddingPlanner.Valuation.Gaps
  alias WeddingPlanner.Valuation.Offer
  alias WeddingPlanner.Valuation.Preset
  alias WeddingPlanner.Valuation.Selection
  alias WeddingPlanner.Valuation.Snapshot

  @priorities [:must_have, :nice_to_have, :not_wanted]

  @typedoc "One line of an offer as the matrix shows it (see the moduledoc)."
  @type line_entry :: %{
          line: OfferLine.t(),
          inclusion: Selection.inclusion(),
          total: Money.t() | nil,
          invalid: boolean()
        }

  @typedoc "One offer × service cell (`CST-52`)."
  @type cell :: %{
          lines: [line_entry()],
          effectively_wanted?: boolean(),
          override: nil | %{wanted: boolean(), deviates?: boolean()},
          scope: nil | :in | :out,
          gap: Gaps.gap() | nil
        }

  @typedoc "One offer column (`CST-53`, `CST-54`, `CST-55`, `XC-42`)."
  @type column :: %{
          offer: Offers.Offer.t(),
          rejected?: boolean(),
          gaps: [Gaps.gap()],
          gap_counts: %{
            must_have: non_neg_integer(),
            nice_to_have: non_neg_integer(),
            unknown: non_neg_integer()
          },
          needs_attention?: boolean(),
          total: Formula.t() | nil,
          like_for_like?: boolean(),
          range: {Money.t(), Money.t()} | nil
        }

  @typedoc "One band of services sharing a wanted priority (`CST-51`)."
  @type band :: %{
          priority: :must_have | :nice_to_have | :not_wanted,
          rows: [%{service: Service.t(), cells: %{term() => cell()}}]
        }

  @typedoc "The whole matrix of one category (`DR-57`)."
  @type t :: %{
          category: Category.t(),
          columns: [column()],
          bands: [band()],
          other_charges: %{term() => [line_entry()]}
        }

  @doc """
  The comparison matrix of the category `category_id` (see the moduledoc).

  `selected_preset` is the preset the totals are computed under (`nil`: every total is
  `nil`); `range_presets` the two presets whose totals give each column's range (`nil`:
  every range is `nil`). Raises `ArgumentError` when the category is not in the snapshot.
  """
  @spec build(Snapshot.t(), term(), Preset.t() | nil, {Preset.t(), Preset.t()} | nil) :: t()
  def build(%Snapshot{} = snapshot, category_id, selected_preset, range_presets)
      when (is_nil(selected_preset) or is_struct(selected_preset, Preset)) and
             (is_nil(range_presets) or
                (is_tuple(range_presets) and tuple_size(range_presets) == 2 and
                   is_struct(elem(range_presets, 0), Preset) and
                   is_struct(elem(range_presets, 1), Preset))) do
    category = category!(snapshot, category_id)

    offers =
      snapshot.offers
      |> Enum.filter(&(&1.category_id == category_id))
      |> Enum.sort_by(& &1.id)

    # The category's services in the order `Selection` and `Gaps` use; `services/2` reads
    # only the offer's category, so a bare offer of this category asks for exactly that.
    services = Selection.services(snapshot, %Offers.Offer{category_id: category_id})
    no_overrides = %{snapshot | overrides: []}

    evaluated =
      Enum.map(
        offers,
        &evaluate(snapshot, no_overrides, &1, services, selected_preset, range_presets)
      )

    %{
      category: category,
      columns: Enum.map(evaluated, & &1.column),
      bands: bands(services, evaluated),
      other_charges: Map.new(evaluated, &{&1.column.offer.id, &1.other_charges})
    }
  end

  # -- one offer ------------------------------------------------------------------------------

  defp evaluate(snapshot, no_overrides, offer, services, selected_preset, range_presets) do
    totals = totals(snapshot, offer, selected_preset, range_presets)
    line_totals = line_totals(snapshot, offer, selected_preset)

    entries =
      for line <- Selection.lines(snapshot, offer) do
        inclusion = Selection.inclusion(snapshot, offer, line)

        %{
          line: line,
          inclusion: inclusion,
          total: if(inclusion == :counted, do: Map.get(line_totals, line.id)),
          invalid: OfferLine.invalid?(line)
        }
      end

    gaps = Gaps.for_offer(snapshot, offer)

    cells =
      Map.new(services, fn service ->
        {service.id, cell(snapshot, no_overrides, offer, service, entries, gaps)}
      end)

    column = %{
      offer: offer,
      rejected?: offer.status == :rejected,
      gaps: gaps,
      gap_counts: gap_counts(gaps),
      needs_attention?: Offer.needs_attention?(snapshot, offer),
      total: selected_preset && Map.fetch!(totals, selected_preset),
      like_for_like?: gaps == [],
      range: range(totals, range_presets)
    }

    %{
      column: column,
      cells: cells,
      other_charges: Enum.filter(entries, &is_nil(&1.line.service_id))
    }
  end

  defp cell(snapshot, no_overrides, offer, service, entries, gaps) do
    %{
      lines: Enum.filter(entries, &(&1.line.service_id == service.id)),
      effectively_wanted?: Selection.effectively_wanted?(snapshot, offer, service),
      override: override(snapshot, no_overrides, offer, service),
      scope: scope(snapshot, offer, service),
      gap: Enum.find(gaps, &(&1.service.id == service.id))
    }
  end

  # DR-64: a confirmed offer's cell shows its scope; any other offer's has none.
  defp scope(snapshot, %Offers.Offer{status: :confirmed} = offer, service) do
    if Selection.in_confirmed_scope?(snapshot, offer, service), do: :in, else: :out
  end

  defp scope(_snapshot, _offer, _service), do: nil

  # DR-64: a confirmed offer's override rows are dormant — no marker at all.
  defp override(_snapshot, _no_overrides, %Offers.Offer{status: :confirmed}, _service), do: nil

  # DR-49: the last matching row, as `Selection` takes it. DR-56: it deviates when its
  # `wanted` differs from what the priority alone gives (Selection with no rows at all).
  defp override(snapshot, no_overrides, offer, service) do
    row =
      snapshot.overrides
      |> Enum.filter(&(&1.offer_id == offer.id and &1.service_id == service.id))
      |> List.last()

    case row do
      nil ->
        nil

      %{wanted: wanted} ->
        wanted = wanted == true
        default = Selection.effectively_wanted?(no_overrides, offer, service)
        %{wanted: wanted, deviates?: wanted != default}
    end
  end

  # -- totals (CST-53) ------------------------------------------------------------------------

  # `Offer.total/4` under every distinct preset the column needs, each evaluated once.
  defp totals(snapshot, offer, selected_preset, range_presets) do
    range_list =
      case range_presets do
        nil -> []
        {low, high} -> [low, high]
      end

    [selected_preset | range_list]
    |> Enum.reject(&is_nil/1)
    |> Enum.uniq()
    |> Map.new(&{&1, Offer.total(snapshot, offer, &1)})
  end

  defp line_totals(_snapshot, _offer, nil), do: %{}

  defp line_totals(snapshot, offer, %Preset{} = preset) do
    snapshot
    |> Offer.breakdown(offer, preset)
    |> Map.fetch!(:lines)
    |> Map.new(&{&1.line.id, &1.total})
  end

  defp range(_totals, nil), do: nil

  defp range(totals, {a, b}) do
    %Formula{total: {:money, total_a}} = Map.fetch!(totals, a)
    %Formula{total: {:money, total_b}} = Map.fetch!(totals, b)

    case Money.compare!(total_a, total_b) do
      :gt -> {total_b, total_a}
      _ -> {total_a, total_b}
    end
  end

  defp gap_counts(gaps) do
    Enum.reduce(gaps, %{must_have: 0, nice_to_have: 0, unknown: 0}, fn gap, counts ->
      Map.update!(counts, gap.severity, &(&1 + 1))
    end)
  end

  # -- bands (CST-51) -------------------------------------------------------------------------

  defp bands(services, evaluated) do
    for priority <- @priorities do
      rows =
        for service <- services, service.wanted_priority == priority do
          cells =
            Map.new(evaluated, fn %{column: column, cells: cells} ->
              {column.offer.id, Map.fetch!(cells, service.id)}
            end)

          %{service: service, cells: cells}
        end

      %{priority: priority, rows: rows}
    end
  end

  defp category!(%Snapshot{categories: categories}, category_id) do
    Enum.find(categories, &(&1.id == category_id)) ||
      raise ArgumentError, "category #{inspect(category_id)} is not in the snapshot"
  end
end
