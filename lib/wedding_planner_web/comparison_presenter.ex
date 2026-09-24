defmodule WeddingPlannerWeb.ComparisonPresenter do
  @moduledoc """
  The price-summary wording of the comparison matrix (task 65; `DR-57`;
  `docs/modules/offers-and-comparison.md` `CST-52`): turns
  `WeddingPlanner.Valuation.Comparison.line_entry/0` structs — already-computed inputs,
  never re-derived here — into display fragments for a service cell or an "other
  charges" column. Pure web-layer formatting, same spirit as
  `WeddingPlannerWeb.FormulaPresenter`: money only ever goes through
  `WeddingPlannerWeb.Format.money/1` (`NFR-14`), nothing here counts, prices or decides
  a gap.

  ## Wording (one fragment per line, `Selection` order)

    * a **counted, priced** line: the line's own **rate** (never the extended total —
      that is what the formula disclosure is for), `WeddingPlannerWeb.Format.money/1`
      formatted, with a basis suffix (`" / adult"`, `" / child"`, `" / attendee"`, none
      for flat), any set modifier in parentheses (`"(first 50 included)"`,
      `"(min. € 6.800,00)"`, included quantity before minimum charge — `CST-36`'s own
      order), and, for a VAT-exclusive offer, `" excl."` appended right after the
      amount (before the basis suffix);
    * an **unpriced state** (`:included`, `:not_offered`, `:unknown`) — `:no_charge`
      inclusion — by its plain name: "Included", "Not offered", "Unknown";
    * a **not counted** optional line (`:not_selected`) — muted: "not selected" for a
      service line (its service is not effectively wanted), "off" for an optional ad hoc
      line (its own toggle, `CST-22`) — `DR-57`'s own wording for the other-charges row;
    * an **invalid** line (`XC-41`/`XC-42`, checked first — a line's validity is
      independent of its state or inclusion) — struck through: "event deleted".

  ## Cell vs. other-charges (`DR-57`)

  `cell_fragments/2` renders a service cell's lines with no label (the row already
  names the service, `CST-52`'s worked example: `"€85 / adult · €40 / child"`).
  `other_charge_fragments/2` renders one column's ad hoc lines (`CST-50`'s "other
  charges" section) with each fragment prefixed by the line's own label — ad hoc lines
  have no shared row to name them, unlike services.

  Both return a plain, ordered list of fragments; joining them (`" · "` for a cell,
  stacked for other charges, per `DR-57`) and applying the `:muted?`/`:struck?` style
  hints is the caller's job — `WeddingPlannerWeb.Components.ComparisonComponents`.
  """

  alias WeddingPlanner.Offers.OfferLine
  alias WeddingPlannerWeb.Format

  @typedoc "One rendered line fragment. `:muted?` and `:struck?` are never both true."
  @type fragment :: %{text: String.t(), muted?: boolean(), struck?: boolean()}

  @doc """
  A service cell's lines (`CST-52`), one fragment per line entry in `Selection` order,
  no label. `vat_basis` is the offer's own (`:inclusive` | `:exclusive`, `CST-33`).
  """
  @spec cell_fragments([map()], :inclusive | :exclusive) :: [fragment()]
  def cell_fragments(line_entries, vat_basis) when vat_basis in [:inclusive, :exclusive] do
    Enum.map(line_entries, &fragment(&1, vat_basis, false))
  end

  @doc """
  A column's other-charges lines (`CST-50`, `DR-57`), one fragment per ad hoc line
  entry, each prefixed with the line's own label.
  """
  @spec other_charge_fragments([map()], :inclusive | :exclusive) :: [fragment()]
  def other_charge_fragments(line_entries, vat_basis)
      when vat_basis in [:inclusive, :exclusive] do
    Enum.map(line_entries, &fragment(&1, vat_basis, true))
  end

  # -- one line (checked in this order: validity first, per XC-42) ----------------------

  defp fragment(%{invalid: true, line: line}, _vat_basis, labelled?) do
    %{text: labelled(line, labelled?, "event deleted"), muted?: false, struck?: true}
  end

  defp fragment(
         %{inclusion: :not_selected, line: %OfferLine{service_id: nil} = line},
         _vat_basis,
         labelled?
       ) do
    %{text: labelled(line, labelled?, "off"), muted?: true, struck?: false}
  end

  defp fragment(%{inclusion: :not_selected, line: line}, _vat_basis, labelled?) do
    %{text: labelled(line, labelled?, "not selected"), muted?: true, struck?: false}
  end

  defp fragment(
         %{inclusion: :no_charge, line: %OfferLine{state: state} = line},
         _vat_basis,
         labelled?
       ) do
    %{text: labelled(line, labelled?, state_name(state)), muted?: false, struck?: false}
  end

  defp fragment(%{inclusion: :counted, line: line}, vat_basis, labelled?) do
    %{
      text: labelled(line, labelled?, priced_summary(line, vat_basis)),
      muted?: false,
      struck?: false
    }
  end

  defp labelled(_line, false, body), do: body
  defp labelled(%OfferLine{label: label}, true, body), do: "#{label}: #{body}"

  defp state_name(:included), do: "Included"
  defp state_name(:not_offered), do: "Not offered"
  defp state_name(:unknown), do: "Unknown"

  # -- a priced line's own rate (CST-52 — never the extended total) ---------------------

  defp priced_summary(%OfferLine{} = line, vat_basis) do
    [amount_summary(line, vat_basis), included_modifier(line), minimum_modifier(line)]
    |> Enum.reject(&is_nil/1)
    |> Enum.join(" ")
  end

  defp amount_summary(%OfferLine{amount: amount, basis: basis}, vat_basis) do
    Format.money(amount) <> excl_suffix(vat_basis) <> basis_suffix(basis)
  end

  defp excl_suffix(:exclusive), do: " excl."
  defp excl_suffix(:inclusive), do: ""

  defp basis_suffix(:flat), do: ""
  defp basis_suffix(:per_adult), do: " / adult"
  defp basis_suffix(:per_child), do: " / child"
  defp basis_suffix(:per_attendee), do: " / attendee"

  defp included_modifier(%OfferLine{included_quantity: nil}), do: nil
  defp included_modifier(%OfferLine{included_quantity: qty}), do: "(first #{qty} included)"

  defp minimum_modifier(%OfferLine{minimum_charge: nil}), do: nil
  defp minimum_modifier(%OfferLine{minimum_charge: amount}), do: "(min. #{Format.money(amount)})"
end
