defmodule WeddingPlannerWeb.HomeOverview do
  @moduledoc """
  The pure view-model behind `/home` (`docs/modules/home.md` `HOME-01`…`HOME-07`): a
  plain map of display strings and ids that `WeddingPlannerWeb.HomeLive` renders. Built
  from one `WeddingPlanner.Valuation.Snapshot`, the viewer's `today` (`NFR-22`, `DR-44`)
  and the todo list's tasks and graph. No database access and no LiveView concerns
  (`NFR-41`); every figure comes from an existing engine — `Valuation.Budget`,
  `Valuation.Headcount`, `Valuation.Gaps`, `Tasks.TodoList` — and nothing re-derives a
  rule. Money is only formatted (and turned into a bar width by `Money.share/2`, `DR-77`),
  never added here beyond what `WeddingPlanner.Money` offers.

  ## Cards

    * `countdown` — days until the nearest event with a date on or after `today`.
    * `tasks` — the next actionable tasks, overdue first (`HOME-02`).
    * `money` — paid, outstanding and forecast range under the three role presets, plus
      unpaid invoices that are overdue or due next (`HOME-03`).
    * `guests` — Minimum / Likely / Maximum per event and invitation counts (`HOME-04`).
    * `attention` — things that are not tasks but need a decision (`HOME-05`).
  """

  alias WeddingPlanner.Categories.Category
  alias WeddingPlanner.Offers.Offer
  alias WeddingPlanner.Offers.OfferLine
  alias WeddingPlanner.Tasks.Graph
  alias WeddingPlanner.Tasks.TodoList
  alias WeddingPlanner.Valuation.Budget
  alias WeddingPlanner.Valuation.Gaps
  alias WeddingPlanner.Valuation.Headcount
  alias WeddingPlanner.Valuation.Invoices, as: InvoiceValuation
  alias WeddingPlanner.Valuation.PresetChoice
  alias WeddingPlanner.Valuation.Snapshot
  alias WeddingPlannerWeb.Format

  @task_limit 5
  @invoice_limit 4
  @attention_limit 6

  @spec build(Snapshot.t(), Date.t(), {[struct()], Graph.t()}) :: map()
  def build(%Snapshot{} = snapshot, %Date{} = today, {tasks, graph}) do
    %{
      countdown: countdown(snapshot, today),
      tasks: tasks_card(tasks, graph, today),
      money: money_card(snapshot, today),
      guests: guests_card(snapshot),
      attention: attention_card(snapshot)
    }
  end

  # -- countdown -----------------------------------------------------------------------------

  defp countdown(%Snapshot{events: events}, today) do
    events
    |> Enum.filter(&(match?(%Date{}, &1.date) and Date.compare(&1.date, today) != :lt))
    |> case do
      [] ->
        nil

      upcoming ->
        event = Enum.min_by(upcoming, & &1.date, Date)
        %{event: event.name, days: Date.diff(event.date, today), date: Format.date(event.date)}
    end
  end

  # -- tasks (HOME-02) -----------------------------------------------------------------------

  defp tasks_card(tasks, graph, today) do
    all = TodoList.build(tasks, graph, TodoList.default_filters(), today)

    actionable =
      TodoList.build(
        tasks,
        graph,
        %{TodoList.default_filters() | chips: MapSet.new([:actionable])},
        today
      )

    items =
      actionable.sections
      |> Enum.flat_map(fn section -> Enum.map(section.tasks, &{section.id, &1}) end)
      |> Enum.take(@task_limit)
      |> Enum.map(fn {section_id, task} ->
        deadline = Graph.effective_deadline(graph, task.id)
        {text, tone} = due(section_id, deadline, today)
        %{id: task.id, title: task.title, due: text, tone: tone}
      end)

    %{
      items: items,
      blocked_count: all.total_not_done - actionable.shown,
      open_count: all.total_not_done
    }
  end

  defp due(:overdue, deadline, today) do
    days = Date.diff(today, deadline)
    {"Overdue · #{days} #{if days == 1, do: "day", else: "days"}", :bad}
  end

  defp due(:this_week, deadline, today) do
    case Date.diff(deadline, today) do
      0 -> {"Due today", :warn}
      1 -> {"Due tomorrow", :warn}
      n -> {"Due in #{n} days", :warn}
    end
  end

  defp due(:later, deadline, _today), do: {"Due #{Format.date(deadline)}", :neutral}
  defp due(:no_deadline, _deadline, _today), do: {"No deadline", :neutral}

  # -- money (HOME-03) -----------------------------------------------------------------------

  defp money_card(%Snapshot{} = snapshot, today) do
    case Budget.for_roles(snapshot) do
      :missing ->
        %{status: :missing_presets, invoices: invoices(snapshot, today)}

      {:ok, %{minimum: min, likely: likely, maximum: max}} ->
        {low, high} = ordered(money(min.forecast), money(max.forecast))

        %{
          status: :ok,
          budget: likely.overall_budget && Format.money(likely.overall_budget),
          forecast: range(low, high),
          paid: Format.money(likely.paid),
          outstanding: Format.money(likely.outstanding),
          available: available(min, max),
          over_budget: likely.over_budget && Format.money(likely.over_budget),
          bar: bar(likely),
          invoices: invoices(snapshot, today)
        }
    end
  end

  defp money(%WeddingPlanner.Valuation.Formula{total: {:money, %Money{} = money}}), do: money

  defp ordered(a, b) do
    case WeddingPlanner.Money.compare(a, b) do
      :gt -> {b, a}
      _ -> {a, b}
    end
  end

  defp range(low, high) do
    if WeddingPlanner.Money.compare(low, high) == :eq,
      do: Format.money(low),
      else: "#{Format.money(low)} – #{Format.money(high)}"
  end

  defp available(%{available: :no_budget}, _max), do: :no_budget

  defp available(min, max) do
    {low, high} = ordered(money(min.available), money(max.available))
    range(low, high)
  end

  # Paid, still-to-pay (invoiced, unpaid), the rest of the forecast and — with a budget
  # set — what is left, as widths of the larger of budget and forecast (`Money.share/2`).
  defp bar(overall) do
    zero = WeddingPlanner.Money.new(0)
    forecast = money(overall.forecast)

    scale =
      case overall.overall_budget do
        nil -> forecast
        budget -> WeddingPlanner.Money.max(budget, forecast)
      end

    rest =
      WeddingPlanner.Money.max(WeddingPlanner.Money.subtract(forecast, overall.invoiced), zero)

    left =
      case overall.overall_budget do
        nil -> zero
        budget -> WeddingPlanner.Money.max(WeddingPlanner.Money.subtract(budget, forecast), zero)
      end

    [
      {"paid", "Paid", overall.paid, "bg-good"},
      {"outstanding", "To pay", overall.outstanding, "bg-info"},
      {"forecast", "Rest of forecast", rest, "bg-warn"},
      {"left", "Left", left, "bg-line-strong"}
    ]
    |> Enum.reject(fn {_key, _label, amount, _tone} ->
      WeddingPlanner.Money.compare(amount, zero) == :eq
    end)
    |> Enum.map(fn {key, label, amount, tone} ->
      %{
        key: key,
        label: label,
        amount: Format.money(amount),
        pct:
          amount |> WeddingPlanner.Money.share(scale) |> Decimal.mult(100) |> Decimal.to_float(),
        tone: tone
      }
    end)
  end

  # Unpaid invoices with a due date: overdue first, then the soonest due.
  defp invoices(%Snapshot{invoices: invoices} = snapshot, today) do
    invoices
    |> Enum.filter(&(not InvoiceValuation.paid?(&1) and match?(%Date{}, &1.due_date)))
    |> Enum.sort_by(& &1.due_date, Date)
    |> Enum.take(@invoice_limit)
    |> Enum.map(fn invoice ->
      %{
        id: invoice.id,
        label: invoice.label,
        due: Format.date(invoice.due_date),
        amount: Format.money(InvoiceValuation.total(snapshot, invoice)),
        overdue?: InvoiceValuation.overdue?(invoice, today)
      }
    end)
  end

  # -- guests (HOME-04) ----------------------------------------------------------------------

  defp guests_card(%Snapshot{} = snapshot) do
    statuses = Enum.frequencies_by(snapshot.invitations, & &1.status)

    base = %{
      invitations:
        for {key, label} <- [
              planned: "Planned",
              invited: "Invited",
              accepted: "Accepted",
              declined: "Declined"
            ] do
          %{key: Atom.to_string(key), label: label, count: Map.get(statuses, key, 0)}
        end,
      people: Enum.count(snapshot.persons, &is_nil(&1.host_id)),
      possible_plus_ones: Enum.count(snapshot.persons, &(&1.plus_one_status == :possible))
    }

    case PresetChoice.role_presets(snapshot.headcount_presets) do
      :missing ->
        Map.merge(base, %{status: :missing_presets, events: []})

      {:ok, %{minimum: min, likely: likely, maximum: max}} ->
        events =
          for event <- snapshot.events do
            count = fn preset -> Headcount.evaluate(snapshot, preset, event).total end

            %{
              id: event.id,
              name: event.name,
              min: count.(min),
              likely: count.(likely),
              max: count.(max)
            }
          end

        Map.merge(base, %{status: :ok, events: events})
    end
  end

  # -- needs attention (HOME-05) -------------------------------------------------------------

  defp attention_card(%Snapshot{} = snapshot) do
    items =
      gap_items(snapshot) ++ invalid_line_items(snapshot) ++ undecided_category_items(snapshot)

    %{items: Enum.take(items, @attention_limit), more: max(length(items) - @attention_limit, 0)}
  end

  # The offers the budget is built on: confirmed ones, plus a planning pick in a
  # category with none (`CST-44`).
  defp basis_offers(%Snapshot{offers: offers}) do
    confirmed_categories =
      for %Offer{status: :confirmed, category_id: id} <- offers, into: MapSet.new(), do: id

    Enum.filter(offers, fn offer ->
      offer.status == :confirmed or
        (offer.planning_pick and not MapSet.member?(confirmed_categories, offer.category_id))
    end)
  end

  defp gap_items(snapshot) do
    for offer <- basis_offers(snapshot),
        names =
          for(
            %{severity: :must_have, service: service} <- Gaps.for_offer(snapshot, offer),
            do: service.name
          ),
        names != [] do
      %{
        id: "gap-#{offer.id}",
        text: "#{offer.vendor_name}: must-have missing — #{Enum.join(names, ", ")}",
        path: "/offers/#{offer.id}"
      }
    end
  end

  defp invalid_line_items(snapshot) do
    for offer <- basis_offers(snapshot),
        count =
          Enum.count(snapshot.offer_lines, &(&1.offer_id == offer.id and OfferLine.invalid?(&1))),
        count > 0 do
      %{
        id: "invalid-#{offer.id}",
        text:
          "#{offer.vendor_name}: #{count} #{if count == 1, do: "line is", else: "lines are"} invalid (event deleted)",
        path: "/offers/#{offer.id}"
      }
    end
  end

  defp undecided_category_items(%Snapshot{categories: categories, offers: offers}) do
    for %Category{id: id, name: name} <- categories,
        category_offers = Enum.filter(offers, &(&1.category_id == id)),
        category_offers != [],
        Enum.all?(category_offers, &(&1.status != :confirmed and not &1.planning_pick)) do
      %{
        id: "undecided-#{id}",
        text: "#{name}: no offer confirmed or picked yet",
        path: "/categories/#{id}"
      }
    end
  end
end
