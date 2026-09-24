defmodule WeddingPlannerWeb.ComparisonPresenterTest do
  @moduledoc """
  `WeddingPlannerWeb.ComparisonPresenter` (task 65, `DR-57`, `CST-52`) — pure formatting
  over plain `WeddingPlanner.Valuation.Comparison.line_entry/0`-shaped maps, no
  database, no snapshot.
  """
  use ExUnit.Case, async: true

  alias WeddingPlanner.Offers.OfferLine
  alias WeddingPlannerWeb.ComparisonPresenter, as: Presenter
  alias WeddingPlannerWeb.Format

  defp money(amount), do: Format.money(WeddingPlanner.Money.new(amount))

  defp entry(line, inclusion, invalid \\ false) do
    %{line: line, inclusion: inclusion, total: nil, invalid: invalid}
  end

  describe "cell_fragments/2" do
    test "a flat priced (counted) line shows its own amount, no basis suffix" do
      line = %OfferLine{amount: WeddingPlanner.Money.new(4000), basis: :flat}

      assert [%{text: text, muted?: false, struck?: false}] =
               Presenter.cell_fragments([entry(line, :counted)], :inclusive)

      assert text == money(4000)
    end

    test "per adult / per child lines join as separate fragments (worked example wording)" do
      adult = %OfferLine{amount: WeddingPlanner.Money.new(85), basis: :per_adult}
      child = %OfferLine{amount: WeddingPlanner.Money.new(40), basis: :per_child}

      assert [adult_fragment, child_fragment] =
               Presenter.cell_fragments(
                 [entry(adult, :counted), entry(child, :counted)],
                 :inclusive
               )

      assert adult_fragment.text == "#{money(85)} / adult"
      assert child_fragment.text == "#{money(40)} / child"
    end

    test "per attendee basis suffix" do
      line = %OfferLine{amount: WeddingPlanner.Money.new(12), basis: :per_attendee}

      assert [%{text: text}] = Presenter.cell_fragments([entry(line, :counted)], :inclusive)
      assert text == "#{money(12)} / attendee"
    end

    test "a VAT-exclusive offer appends \" excl.\" right after the amount" do
      line = %OfferLine{amount: WeddingPlanner.Money.new(85), basis: :per_adult}

      assert [%{text: text}] = Presenter.cell_fragments([entry(line, :counted)], :exclusive)
      assert text == "#{money(85)} excl. / adult"
    end

    test "modifiers render in parentheses, included quantity before minimum charge" do
      line = %OfferLine{
        amount: WeddingPlanner.Money.new(85),
        basis: :per_adult,
        included_quantity: 50,
        minimum_charge: WeddingPlanner.Money.new(6800)
      }

      assert [%{text: text}] = Presenter.cell_fragments([entry(line, :counted)], :inclusive)
      assert text == "#{money(85)} / adult (first 50 included) (min. #{money(6800)})"
    end

    test "unpriced states render by name" do
      for {state, expected} <- [
            {:included, "Included"},
            {:not_offered, "Not offered"},
            {:unknown, "Unknown"}
          ] do
        line = %OfferLine{state: state}

        assert [%{text: ^expected, muted?: false, struck?: false}] =
                 Presenter.cell_fragments([entry(line, :no_charge)], :inclusive)
      end
    end

    test "a not-selected optional service line is muted \"not selected\"" do
      line = %OfferLine{
        service_id: 1,
        state: :optional,
        amount: WeddingPlanner.Money.new(500),
        basis: :flat
      }

      assert [%{text: "not selected", muted?: true, struck?: false}] =
               Presenter.cell_fragments([entry(line, :not_selected)], :inclusive)
    end

    test "an invalid line is struck through with \"event deleted\", regardless of inclusion" do
      line = %OfferLine{basis: :per_adult, amount: WeddingPlanner.Money.new(85)}

      assert [%{text: "event deleted", muted?: false, struck?: true}] =
               Presenter.cell_fragments([entry(line, :counted, true)], :inclusive)
    end

    test "order is preserved and fragments are returned one per line" do
      a = %OfferLine{state: :included}
      b = %OfferLine{amount: WeddingPlanner.Money.new(10), basis: :flat}

      assert [%{text: "Included"}, %{text: text}] =
               Presenter.cell_fragments([entry(a, :no_charge), entry(b, :counted)], :inclusive)

      assert text == money(10)
    end
  end

  describe "other_charge_fragments/2" do
    test "labels a counted ad hoc line with its own label" do
      line = %OfferLine{label: "Base price", amount: WeddingPlanner.Money.new(4000), basis: :flat}

      assert [%{text: text, muted?: false, struck?: false}] =
               Presenter.other_charge_fragments([entry(line, :counted)], :inclusive)

      assert text == "Base price: #{money(4000)}"
    end

    test "an off optional ad hoc line is muted \"off\", not \"not selected\" (DR-57)" do
      line = %OfferLine{
        label: "Late checkout",
        state: :optional,
        amount: WeddingPlanner.Money.new(100),
        basis: :flat,
        enabled: false
      }

      assert [%{text: "Late checkout: off", muted?: true, struck?: false}] =
               Presenter.other_charge_fragments([entry(line, :not_selected)], :inclusive)
    end

    test "an invalid ad hoc line is struck through with its label" do
      line = %OfferLine{
        label: "Cleaning fee",
        basis: :flat,
        amount: WeddingPlanner.Money.new(350)
      }

      assert [%{text: "Cleaning fee: event deleted", struck?: true}] =
               Presenter.other_charge_fragments([entry(line, :counted, true)], :inclusive)
    end
  end
end
