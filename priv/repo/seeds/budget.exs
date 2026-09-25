defmodule WeddingPlanner.Seeds.Budget do
  @moduledoc """
  `DR-76` demo data for `/budget` (task 82): an overall budget, a confirmed-and-invoiced
  Photography offer (so the `:confirmed` / `source: :invoicing_complete` branch of
  `BUD-03` has a real category), and a target for Flowers (the `:target` branch). Venue's
  own confirmed-but-not-complete offer (`Seeds.Confirmations`), the Flowers/Attire
  planning pick, and Church's empty category already cover the rest of `BUD-03`'s
  branches — see the moduledoc table in `WeddingPlanner.BudgetSnapshots` for the parallel
  test fixture.

  Every write goes through the real contexts (`WeddingPlanner.Settings.update/3`,
  `WeddingPlanner.Offers`, `WeddingPlanner.Invoices`, `WeddingPlanner.Categories`), so
  each gets a real activity-log entry (`XC-10`) and real broadcasts (`XC-01`) — never
  `Repo.insert!`/`Repo.update!` directly. Money is only ever parsed from an nl-BE input
  string (`DR-23`), never built from one directly (`DR-18`).

  Idempotent (`DR-79`'s per-block tracking in `demo.exs` already guarantees this block
  runs at most once against a given database, but each step also guards itself so a
  manual re-run — or a partially-applied database from before this guarantee existed —
  never duplicates or crashes): the overall budget is set only while unset; the
  Photography offer only while the category has no confirmed offer; the invoice is
  linked only while it exists and is still unlinked; the Flowers target only while unset.
  Prints one summary line, or a "skipping" line when its prerequisites (the categories
  and the "Photographer invoice" from `seeds/categories.exs` / `seeds/invoices.exs`) are
  missing — never raises.
  """

  alias WeddingPlanner.Accounts.Scope
  alias WeddingPlanner.Categories
  alias WeddingPlanner.Invoices
  alias WeddingPlanner.Offers
  alias WeddingPlanner.Settings

  @overall_budget_input "45.000"
  @flowers_target_input "1.200"
  @photography_vendor "Studio Licht"
  @photography_amount_input "2.200"

  @spec run(Scope.t()) :: :ok
  def run(%Scope{} = scope) do
    steps = [
      set_overall_budget(scope),
      confirm_photography(scope),
      set_flowers_target(scope)
    ]

    case Enum.reject(steps, &(&1 == :skipped)) do
      [] ->
        IO.puts("skipping budget demo data — already applied or its prerequisites are missing")

      applied ->
        IO.puts("budget: " <> Enum.join(applied, ", "))
    end

    :ok
  end

  # -- overall budget (BUD-01) ----------------------------------------------------------

  defp set_overall_budget(scope) do
    settings = Settings.get()

    if is_nil(settings.overall_budget) do
      {:ok, _updated} =
        Settings.update(scope, settings, %{
          "overall_budget_input" => @overall_budget_input,
          "default_time_zone" => settings.default_time_zone
        })

      "set overall budget to € #{@overall_budget_input}"
    else
      :skipped
    end
  end

  # -- Photography: confirmed, invoicing complete (BUD-03 :confirmed / :invoicing_complete) --

  defp confirm_photography(scope) do
    case category("Photography") do
      nil ->
        :skipped

      category ->
        if Offers.category_has_confirmed_offer?(category) do
          :skipped
        else
          {:ok, offer} =
            Offers.create_simple_offer(scope, category, %{
              "vendor_name" => @photography_vendor,
              "amount_input" => @photography_amount_input
            })

          {:ok, confirmed} = Offers.confirm_offer(scope, offer)
          link_and_complete(scope, category, confirmed)
          "confirmed '#{@photography_vendor}' for Photography"
        end
    end
  end

  defp link_and_complete(scope, category, confirmed) do
    case Enum.find(Invoices.list_invoices(category), &(&1.label == "Photographer invoice")) do
      %{offer_id: nil} = invoice ->
        {:ok, linked} = Invoices.update_invoice(scope, invoice, %{"offer_id" => confirmed.id})
        {:ok, _} = Invoices.set_invoicing_complete(scope, confirmed, true)
        linked

      _ ->
        {:ok, _} = Invoices.set_invoicing_complete(scope, confirmed, true)
        :ok
    end
  end

  # -- Flowers: target only (BUD-03 :target) ---------------------------------------------

  defp set_flowers_target(scope) do
    case category("Flowers") do
      nil ->
        :skipped

      %{target: nil} = category ->
        {:ok, _updated} =
          Categories.update_category(scope, category, %{"target_input" => @flowers_target_input})

        "set Flowers target to € #{@flowers_target_input}"

      _ ->
        :skipped
    end
  end

  # -- helpers ----------------------------------------------------------------------------

  defp category(name), do: Enum.find(Categories.list_categories(), &(&1.name == name))
end
