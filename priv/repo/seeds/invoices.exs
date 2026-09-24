defmodule WeddingPlanner.Seeds.Invoices do
  @moduledoc """
  `DR-26` Q4 demo invoices (task 69; `docs/modules/invoices-and-budget.md` `BIL-01`
  through `BIL-06`; `DR-59`): one paid invoice, one unpaid invoice due next month, one
  unpaid **overdue** invoice (due date before today, `BIL-06`) and one unpaid invoice
  with no due date — none linked to an offer (`DR-58`: no confirmed offer exists yet in
  this wave). Every write goes through `WeddingPlanner.Invoices`, never `Repo.insert!`
  directly, so each gets a real activity-log entry (`XC-10`) and real validation.
  Amounts use the typed-`Money` programmatic path
  (`WeddingPlanner.Invoices.InvoiceLine`'s moduledoc sanctions it for seeds/fixtures,
  `DR-18`) rather than parsed nl-BE strings.

  Idempotent: runs only while the `invoices` table is empty — see `priv/repo/seeds.exs`.
  Depends on `seeds/categories.exs` having already run (Venue, Catering, Attire,
  Photography).
  """

  alias WeddingPlanner.Accounts.Scope
  alias WeddingPlanner.Categories
  alias WeddingPlanner.Invoices
  alias WeddingPlanner.Invoices.Invoice
  alias WeddingPlanner.Money
  alias WeddingPlanner.Repo

  @spec run(Scope.t()) :: :ok
  def run(%Scope{} = scope) do
    if Repo.aggregate(Invoice, :count) == 0 do
      today = Date.utc_today()

      seed_paid(scope, today)
      seed_due_next_month(scope, today)
      seed_overdue(scope, today)
      seed_no_due_date(scope, today)

      IO.puts("invoices: created 4 demo invoices")
    else
      IO.puts("skipping invoices — already has data")
    end

    :ok
  end

  # -- Venue: paid ------------------------------------------------------------------------

  defp seed_paid(scope, today) do
    category = category!("Venue")

    {:ok, invoice} =
      Invoices.create_invoice(
        scope,
        category,
        %{"label" => "Venue deposit", "invoice_date" => Date.add(today, -60)},
        %{"label" => "Deposit", "amount" => eur(3_000)}
      )

    {:ok, _invoice} = Invoices.mark_paid(scope, invoice, Date.add(today, -25))
  end

  # -- Catering: unpaid, due next month -----------------------------------------------------

  defp seed_due_next_month(scope, today) do
    category = category!("Catering")

    {:ok, _invoice} =
      Invoices.create_invoice(
        scope,
        category,
        %{
          "label" => "Caterer deposit",
          "invoice_date" => Date.add(today, -10),
          "due_date" => Date.add(today, 30)
        },
        %{"label" => "Deposit", "amount" => eur(1_500)}
      )
  end

  # -- Attire: unpaid, overdue (BIL-06) -----------------------------------------------------

  defp seed_overdue(scope, today) do
    category = category!("Attire")

    {:ok, _invoice} =
      Invoices.create_invoice(
        scope,
        category,
        %{
          "label" => "Bridal Boutique invoice",
          "invoice_date" => Date.add(today, -45),
          "due_date" => Date.add(today, -15)
        },
        %{"label" => "Balance", "amount" => eur(1_800)}
      )
  end

  # -- Photography: unpaid, no due date -----------------------------------------------------

  defp seed_no_due_date(scope, today) do
    category = category!("Photography")

    {:ok, _invoice} =
      Invoices.create_invoice(
        scope,
        category,
        %{"label" => "Photographer invoice", "invoice_date" => Date.add(today, -5)},
        %{"label" => "Full day coverage", "amount" => eur(2_200)}
      )
  end

  # -- helpers -----------------------------------------------------------------------------

  defp eur(amount), do: Money.new(amount)

  defp category!(name) do
    Categories.list_categories() |> Enum.find(&(&1.name == name)) ||
      raise "seed category '#{name}' not found — run seeds/categories.exs first"
  end
end
