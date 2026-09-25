defmodule WeddingPlannerWeb.Export.Offers do
  @moduledoc """
  The offers-with-lines CSV export (`XC-30` "offers with lines", `XC-32`, `DR-89`
  option (a)): **one row per offer line**, the offer's own columns repeated on each of
  its rows, so one uniform grid filters and pivots in any spreadsheet.

  ## Rows

    * Offers in `snapshot.categories` order, then by offer id — **rejected offers
      included** (the file is the module's data, not a screen's filtered view).
    * Each offer's lines in `WeddingPlanner.Valuation.Selection.lines/2` order (`DR-41`),
      every line — counted or not.
    * An offer with no lines gets exactly one row whose line cells are all blank.

  ## Columns

  Offer columns, repeated on every row of the offer:

  `Category, Offer, Status, VAT basis, VAT rate (%), Minimum spend, Planning pick,
  Invoicing complete, Offer total — <minimum>, Offer total — <likely>,
  Offer total — <maximum>`

  Line columns:

  `Line, Kind, State, Pricing basis, Event, Amount (offer's VAT basis), Included quantity,
  Minimum charge (offer's VAT basis), Line VAT rate (%), On, Invalid, Counts toward total,
  Line total — <minimum>, Line total — <likely>, Line total — <maximum>`

  then `Currency` (last, the row's currency code; blank when the row has no amount).

    * `<minimum>`/`<likely>`/`<maximum>` are the stored names of the three **role**
      presets (`WeddingPlanner.Valuation.PresetChoice.role_presets/1`, `DR-54`), always
      in that order — every preset-dependent column names its preset (`HC-08`,
      `BUD-04`). If a role is unassigned (defensive, `DR-54`), the headers use the role
      words `Minimum`/`Likely`/`Maximum` and every preset-dependent cell is blank.
    * Status and VAT basis are the UI's words (`considering`, `shortlisted`,
      `rejected`, `confirmed`; `inclusive`, `exclusive`); State `included` /
      `optional` / `mandatory` / `not offered` / `unknown`; Pricing basis `flat` /
      `per adult` / `per child` / `per attendee` (blank for an unpriced state); Kind
      `service` / `ad hoc`; Event the event's name (blank for none).
    * VAT rates are percentages from basis points (`2100` → `21`, `550` → `5.5`) as
      `Decimal`s — percentages, not money (`NFR-12` does not apply); blank when unset.
    * Amount and Minimum charge are stored inputs in the offer's own VAT basis
      (`CST-34`, `CST-36`) — the headers say so.
    * On is the toggle of an optional ad hoc line (`CST-22`), blank for every other
      line. Invalid is `WeddingPlanner.Offers.OfferLine.invalid?/1` (`XC-41`).
    * Counts toward total is `WeddingPlanner.Valuation.Selection.inclusion/3` worded
      `counted` / `no charge` / `not selected` / `outside confirmed scope` (`CST-21`,
      `CST-22`, `CST-24`, `CST-43`).
    * Offer total per role preset is `WeddingPlanner.Valuation.Offer.total/3`'s money —
      VAT inclusive, after the minimum spend (`CST-36`); a confirmed offer's is its
      committed total over the frozen selection (`CST-40`, `CST-41`).
    * Line total per role preset is that line's `total` in
      `WeddingPlanner.Valuation.Offer.breakdown/3` (VAT inclusive). An **invalid**
      counted line appears there at €0 and is written as that €0 with Invalid set — it
      contributes nothing but is never silently dropped (`XC-42`). A line
      `breakdown/3` does not list (not counted) has blank line totals.

  Every figure is the engines' **unrounded** `%Money{}`; the encoder rounds once, on
  output (`NFR-14`), so the displayed line totals of an offer may differ from its
  displayed total by a cent, and a minimum spend makes the total exceed their sum.
  Nothing is computed here: all pricing is the offer engine's (`DR-89`).

  `load/0` is the only database read; `table/2` is pure and ignores `today`.
  """

  alias WeddingPlanner.Offers.OfferLine
  alias WeddingPlanner.Repo
  alias WeddingPlanner.Valuation.Formula
  alias WeddingPlanner.Valuation.Offer, as: OfferEngine
  alias WeddingPlanner.Valuation.Preset
  alias WeddingPlanner.Valuation.PresetChoice
  alias WeddingPlanner.Valuation.Selection
  alias WeddingPlanner.Valuation.Snapshot

  @roles [:minimum, :likely, :maximum]
  @role_words %{minimum: "Minimum", likely: "Likely", maximum: "Maximum"}

  # The number of line columns (everything between the offer columns and Currency).
  @line_column_count 15

  @doc "The live planning state (`XC-32`) — the export's only database read."
  @spec load() :: Snapshot.t()
  def load, do: Snapshot.load(Repo)

  @doc """
  The offers-with-lines table of `snapshot` (see the moduledoc). Pure; `today` is
  accepted for the exporter contract and ignored.
  """
  @spec table(Snapshot.t(), Date.t()) :: WeddingPlannerWeb.Export.Table.t()
  def table(%Snapshot{} = snapshot, _today) do
    presets = role_presets(snapshot)
    names = Enum.map(presets, &column_name/1)

    rows =
      for category <- snapshot.categories,
          offer <- offers_of(snapshot, category),
          row <- offer_rows(snapshot, category, offer, presets),
          do: row

    %{stem: "offers", headers: headers(names), rows: rows}
  end

  defp headers(names) do
    [
      "Category",
      "Offer",
      "Status",
      "VAT basis",
      "VAT rate (%)",
      "Minimum spend",
      "Planning pick",
      "Invoicing complete"
    ] ++
      Enum.map(names, &"Offer total — #{&1}") ++
      [
        "Line",
        "Kind",
        "State",
        "Pricing basis",
        "Event",
        "Amount (offer's VAT basis)",
        "Included quantity",
        "Minimum charge (offer's VAT basis)",
        "Line VAT rate (%)",
        "On",
        "Invalid",
        "Counts toward total"
      ] ++
      Enum.map(names, &"Line total — #{&1}") ++
      ["Currency"]
  end

  # [{role, preset | nil}] in minimum · likely · maximum order.
  defp role_presets(%Snapshot{headcount_presets: presets}) do
    case PresetChoice.role_presets(presets) do
      {:ok, by_role} -> Enum.map(@roles, &{&1, Map.fetch!(by_role, &1)})
      :missing -> Enum.map(@roles, &{&1, nil})
    end
  end

  defp column_name({_role, %Preset{name: name}}), do: name
  defp column_name({role, nil}), do: Map.fetch!(@role_words, role)

  defp offers_of(snapshot, category) do
    snapshot.offers
    |> Enum.filter(&(&1.category_id == category.id))
    |> Enum.sort_by(& &1.id)
  end

  # -- one offer -------------------------------------------------------------------------------

  defp offer_rows(snapshot, category, offer, presets) do
    evaluations = Enum.map(presets, fn {_role, preset} -> evaluate(snapshot, offer, preset) end)

    offer_cells =
      [
        category.name,
        offer.vendor_name,
        Atom.to_string(offer.status),
        Atom.to_string(offer.vat_basis),
        percent(offer.vat_rate_bp),
        offer.minimum_spend,
        offer.planning_pick == true,
        offer.invoicing_complete == true
      ] ++ Enum.map(evaluations, &evaluation_total/1)

    case Selection.lines(snapshot, offer) do
      [] ->
        [with_currency(offer_cells ++ List.duplicate(nil, @line_column_count))]

      lines ->
        Enum.map(
          lines,
          &with_currency(offer_cells ++ line_cells(snapshot, offer, &1, evaluations))
        )
    end
  end

  # One role preset's evaluation of the offer: its total (`Offer.total/3`) and the total of
  # every line `Offer.breakdown/3` prices, by line id. `nil` when the role is unassigned.
  defp evaluate(_snapshot, _offer, nil), do: nil

  defp evaluate(snapshot, offer, %Preset{} = preset) do
    %Formula{total: {:money, %Money{} = total}} = OfferEngine.total(snapshot, offer, preset)
    %{lines: priced} = OfferEngine.breakdown(snapshot, offer, preset)

    %{total: total, line_totals: Map.new(priced, &{&1.line.id, &1.total})}
  end

  defp evaluation_total(nil), do: nil
  defp evaluation_total(%{total: total}), do: total

  # -- one line --------------------------------------------------------------------------------

  defp line_cells(snapshot, offer, %OfferLine{} = line, evaluations) do
    [
      line_name(snapshot, line),
      kind(line),
      state_word(line.state),
      basis_word(line.basis),
      event_name(snapshot, line),
      line.amount,
      line.included_quantity,
      line.minimum_charge,
      percent(line.vat_rate_bp),
      on(line),
      OfferLine.invalid?(line),
      inclusion_word(Selection.inclusion(snapshot, offer, line))
    ] ++ Enum.map(evaluations, &line_total(&1, line))
  end

  defp line_total(nil, _line), do: nil
  defp line_total(%{line_totals: totals}, %OfferLine{id: id}), do: Map.get(totals, id)

  # The name `Offer.breakdown/3` gives a line: its service's name, or its ad hoc label.
  defp line_name(_snapshot, %OfferLine{service_id: nil, label: label}), do: label

  defp line_name(%Snapshot{services: services}, %OfferLine{service_id: service_id}) do
    case Enum.find(services, &(&1.id == service_id)) do
      nil -> nil
      service -> service.name
    end
  end

  defp kind(%OfferLine{service_id: nil}), do: "ad hoc"
  defp kind(%OfferLine{}), do: "service"

  defp event_name(_snapshot, %OfferLine{event_id: nil}), do: nil

  defp event_name(%Snapshot{events: events}, %OfferLine{event_id: event_id}) do
    case Enum.find(events, &(&1.id == event_id)) do
      nil -> nil
      event -> event.name
    end
  end

  # CST-22: only an optional ad hoc line has an on/off toggle.
  defp on(%OfferLine{} = line) do
    if OfferLine.optional_ad_hoc?(line), do: line.enabled == true
  end

  defp state_word(:included), do: "included"
  defp state_word(:optional), do: "optional"
  defp state_word(:mandatory), do: "mandatory"
  defp state_word(:not_offered), do: "not offered"
  defp state_word(:unknown), do: "unknown"

  defp basis_word(nil), do: nil
  defp basis_word(:flat), do: "flat"
  defp basis_word(:per_adult), do: "per adult"
  defp basis_word(:per_child), do: "per child"
  defp basis_word(:per_attendee), do: "per attendee"

  defp inclusion_word(:counted), do: "counted"
  defp inclusion_word(:no_charge), do: "no charge"
  defp inclusion_word(:not_selected), do: "not selected"
  defp inclusion_word(:outside_scope), do: "outside confirmed scope"

  # Basis points as a percentage (`2100` → 21, `550` → 5.5). Not money (NFR-12).
  defp percent(nil), do: nil

  defp percent(bp) when is_integer(bp),
    do: bp |> Decimal.new() |> Decimal.div(100) |> Decimal.normalize()

  defp with_currency(cells), do: cells ++ [currency(cells)]

  defp currency(cells) do
    Enum.find_value(cells, fn
      %Money{currency: currency} -> Atom.to_string(currency)
      _other -> nil
    end)
  end
end
