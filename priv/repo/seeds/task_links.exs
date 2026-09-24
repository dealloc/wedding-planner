defmodule WeddingPlanner.Seeds.TaskLinks do
  @moduledoc """
  `DR-8`/`DR-69` demo (task 78): two of the 23 seeded tasks (`seeds/tasks.exs`) get a
  real offer/invoice link, so `/tasks` shows the new Offers/Invoices optgroups and row
  links without any manual clicking.

  "Finalize seating chart draft" (seeded with no link) is linked to the "Venue A" offer
  (`seeds/offers.exs`) — its "Seating" line is one of Venue A's eight. "Pay venue
  deposit" is repointed from the coarse Venue *category* link `seeds/tasks.exs` gave it
  to the actual "Venue deposit" *invoice* it is about (`seeds/invoices.exs`) — the
  invoice it names is strictly more precise than the category link, and this is exactly
  the kind of edit `Tasks.update_task/3` supports (clearing one link field while setting
  another, both cast in the same call — `WeddingPlanner.Tasks.Task.validate_link/1`
  still only allows one to end up set).

  Idempotent: runs only while no task links to an offer or invoice yet — see
  `priv/repo/seeds.exs`. Depends on `seeds/tasks.exs`, `seeds/offers.exs` and
  `seeds/invoices.exs` having already run.
  """

  import Ecto.Query

  alias WeddingPlanner.Accounts.Scope
  alias WeddingPlanner.Categories
  alias WeddingPlanner.Invoices
  alias WeddingPlanner.Offers
  alias WeddingPlanner.Repo
  alias WeddingPlanner.Tasks
  alias WeddingPlanner.Tasks.Task

  @spec run(Scope.t()) :: :ok
  def run(%Scope{} = scope) do
    already_linked? =
      Repo.exists?(where(Task, [t], not is_nil(t.link_offer_id) or not is_nil(t.link_invoice_id)))

    if already_linked? do
      IO.puts("skipping task links to offers/invoices — already has data")
    else
      by_title = Tasks.list_tasks() |> Map.new(&{&1.title, &1})
      venue = category!("Venue")
      offer = offer!(venue, "Venue A")
      invoice = invoice!(venue, "Venue deposit")

      link_task(scope, by_title, "Finalize seating chart draft", %{link_offer_id: offer.id})

      link_task(scope, by_title, "Pay venue deposit", %{
        link_category_id: nil,
        link_invoice_id: invoice.id
      })

      IO.puts("task links: linked 2 tasks to an offer/invoice")
    end

    :ok
  end

  defp link_task(scope, by_title, title, attrs) do
    task = Map.fetch!(by_title, title)
    {:ok, _task} = Tasks.update_task(scope, task, attrs)
  end

  defp category!(name) do
    Categories.list_categories() |> Enum.find(&(&1.name == name)) ||
      raise "seeds/task_links.exs: missing category #{name}"
  end

  defp offer!(category, vendor_name) do
    Offers.list_offers(category) |> Enum.find(&(&1.vendor_name == vendor_name)) ||
      raise "seeds/task_links.exs: missing offer #{vendor_name}"
  end

  defp invoice!(category, label) do
    Invoices.list_invoices(category) |> Enum.find(&(&1.label == label)) ||
      raise "seeds/task_links.exs: missing invoice #{label}"
  end
end
