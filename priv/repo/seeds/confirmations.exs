defmodule WeddingPlanner.Seeds.Confirmations do
  @moduledoc """
  `DR-26` Q4 demo confirmation and planning pick (task 73;
  `docs/modules/offers-and-comparison.md` `CST-40`–`CST-44`,
  `docs/modules/invoices-and-budget.md` `BIL-01`; `DR-61`–`DR-66`):

    * the Venue category's first offer ("Venue A") is confirmed through
      `WeddingPlanner.Offers.confirm_offer/2` — the same call the screens make, so it gets
      its frozen selection and real activity-log entries (`XC-10`);
    * the seeded "Venue deposit" invoice, when it exists in Venue and is still unlinked, is
      linked to it through `WeddingPlanner.Invoices.update_invoice/3` (`BIL-01`: only a
      confirmed offer can be linked);
    * another category with no confirmed offer and at least two non-rejected offers gets
      a planning pick (`WeddingPlanner.Offers.set_planning_pick/2`, `CST-44`). The earlier
      seeds leave no such category (Catering and Attire have one offer each), so when none
      qualifies a second Catering offer ("Caterer D", one mandatory flat "Price" line,
      typed `Money` — `DR-18`) is added first and Caterer C becomes the pick.

  Idempotent: runs only while **no** offer is confirmed — see `priv/repo/seeds.exs`.
  Depends on `seeds/offers.exs` and `seeds/invoices.exs` having already run.
  """

  import Ecto.Query

  alias WeddingPlanner.Accounts.Scope
  alias WeddingPlanner.Categories
  alias WeddingPlanner.Invoices
  alias WeddingPlanner.Money
  alias WeddingPlanner.Offers
  alias WeddingPlanner.Offers.Offer
  alias WeddingPlanner.Repo

  @spec run(Scope.t()) :: :ok
  def run(%Scope{} = scope) do
    if Repo.exists?(from(o in Offer, where: o.status == :confirmed)) do
      IO.puts("skipping confirmations — an offer is already confirmed")
    else
      confirmed = confirm_venue(scope)
      picked = seed_planning_pick(scope, confirmed)

      IO.puts(
        "confirmations: confirmed #{describe(confirmed)}, planning pick #{describe(picked)}"
      )
    end

    :ok
  end

  # -- Venue: confirm the first offer, link the deposit ------------------------------------

  defp confirm_venue(scope) do
    with %{} = venue <- category("Venue"),
         [first | _] <- Offers.list_offers(venue) do
      {:ok, confirmed} = Offers.confirm_offer(scope, first)
      link_deposit(scope, venue, confirmed)
      confirmed
    else
      _ -> nil
    end
  end

  defp link_deposit(scope, venue, confirmed) do
    case Enum.find(Invoices.list_invoices(venue), &(&1.label == "Venue deposit")) do
      %{offer_id: nil} = deposit ->
        {:ok, _} = Invoices.update_invoice(scope, deposit, %{"offer_id" => confirmed.id})

      _ ->
        :ok
    end
  end

  # -- Planning pick in another category (CST-44) -------------------------------------------

  defp seed_planning_pick(scope, confirmed) do
    excluded_category_id = confirmed && confirmed.category_id

    candidate =
      Categories.list_categories()
      |> Enum.reject(&(&1.id == excluded_category_id))
      |> Enum.reject(&Offers.category_has_confirmed_offer?/1)
      |> Enum.find(&(length(open_offers(&1)) >= 2))

    category = candidate || add_second_catering_offer(scope)

    case category && open_offers(category) do
      [first | _] ->
        {:ok, picked} = Offers.set_planning_pick(scope, first)
        picked

      _ ->
        nil
    end
  end

  defp add_second_catering_offer(scope) do
    case category("Catering") do
      nil ->
        nil

      catering ->
        if length(open_offers(catering)) < 2 do
          {:ok, offer} = Offers.create_offer(scope, catering, %{"vendor_name" => "Caterer D"})

          {:ok, _line} =
            Offers.create_line(scope, offer, %{
              "label" => "Price",
              "state" => "mandatory",
              "basis" => "flat",
              "amount" => Money.new(6_900)
            })
        end

        catering
    end
  end

  # -- helpers -------------------------------------------------------------------------------

  defp open_offers(category) do
    category |> Offers.list_offers() |> Enum.reject(&(&1.status in [:rejected, :confirmed]))
  end

  defp category(name), do: Enum.find(Categories.list_categories(), &(&1.name == name))

  defp describe(nil), do: "none"
  defp describe(%Offer{vendor_name: vendor}), do: "'#{vendor}'"
end
