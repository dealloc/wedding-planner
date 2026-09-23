defmodule WeddingPlanner.Seeds.Tasks do
  @moduledoc """
  `DR-26` Q4 demo todo list: 23 tasks — the scale the `/tasks` screens were judged at
  (`.claude/design/ui-decisions.md` "Todo list v2", "Seeded with 23 tasks") — spread
  across every deadline shape (overdue, due this week, later, none, and three relative
  deadlines, including the normative T4 example "Send invitations — 12 weeks before
  Reception", left unresolved because Reception has no date), every owner shape (the
  actor, "Both", "Nobody", and a second assignable user when one exists), a few
  in-progress/done tasks, and a mix of event/category links. Fixed dates are computed
  from `Date.utc_today/0` so "overdue"/"this week"/"later" stay meaningful however long
  after seeding this is viewed. Idempotent: runs only while the `tasks` table is empty —
  see `priv/repo/seeds.exs`.

  ## Dependency chains (task 43, `TSK-10`–`TSK-15`, `DR-35`/`DR-36`)

  A second, independently idempotent block (`seed_dependencies/1`, gated on
  `WeddingPlanner.Tasks.list_dependencies/0` being empty rather than on the task table,
  so it still runs — and only runs once — against an already-seeded database) lays four
  edges over the 23 tasks above, through `WeddingPlanner.Tasks.add_dependency/3` like any
  other write:

    * `"Order wedding rings"` waits on `"Write wedding vows"` (no own deadline)
      — **T2**: "Write wedding vows" gains "Order wedding rings"' effective deadline.
    * `"Book hair & makeup trial"` and `"Arrange transportation"` both wait on
      `"Order wedding rings"` — a branching chain (two tasks waiting on one), and,
      chained with the edge above, a 3-deep transitive tree for `TSK-15`.
    * `"Taste-test catering menu"` waits on `"Confirm final headcount"` — **T3**:
      "Confirm final headcount" is due later (`+200` days) than "Taste-test catering
      menu" (`+3` days), so its own deadline conflicts with what waits on it.

  Every dependent task above is `:to_do`, so every prerequisite's waiter is also
  `TSK-11` **blocked** — "Order wedding rings", "Book hair & makeup trial",
  "Arrange transportation" and "Taste-test catering menu" all show the Blocked badge.
  """

  alias WeddingPlanner.Accounts.Scope
  alias WeddingPlanner.Accounts.User
  alias WeddingPlanner.Categories
  alias WeddingPlanner.Events
  alias WeddingPlanner.Repo
  alias WeddingPlanner.Tasks
  alias WeddingPlanner.Tasks.Task

  # `{dependent title, prerequisite title}` — `dependent` waits on `prerequisite`
  # (`DR-35`'s direction), both drawn from `tasks/4`'s 23 titles below.
  @dependency_chains [
    {"Order wedding rings", "Write wedding vows"},
    {"Book hair & makeup trial", "Order wedding rings"},
    {"Arrange transportation", "Order wedding rings"},
    {"Taste-test catering menu", "Confirm final headcount"}
  ]

  @spec run(Scope.t(), User.t() | nil) :: :ok
  def run(%Scope{} = scope, second_user) do
    if Repo.aggregate(Task, :count) == 0 do
      events = Events.list_events() |> Map.new(&{&1.name, &1})
      categories = Categories.list_categories() |> Map.new(&{&1.name, &1})
      actor_id = scope.user.id
      second_id = if second_user, do: second_user.id, else: actor_id

      tasks_list = tasks(actor_id, second_id, events, categories)
      Enum.each(tasks_list, fn attrs -> {:ok, _task} = Tasks.create_task(scope, attrs) end)

      IO.puts("tasks: created #{length(tasks_list)} tasks")
    else
      IO.puts("skipping tasks — already has data")
    end

    seed_dependencies(scope)

    :ok
  end

  # Idempotent on its own axis (`task_dependencies` empty, not `tasks` empty) so this
  # still lays the demo chains the first time it runs against a database whose tasks
  # were seeded before this block existed — and lays nothing on every run after that.
  defp seed_dependencies(scope) do
    if Tasks.list_dependencies() == [] do
      by_title = Tasks.list_tasks() |> Map.new(&{&1.title, &1})

      Enum.each(@dependency_chains, fn {dependent_title, prerequisite_title} ->
        dependent = Map.fetch!(by_title, dependent_title)
        prerequisite = Map.fetch!(by_title, prerequisite_title)
        {:ok, _dependency} = Tasks.add_dependency(scope, dependent, prerequisite)
      end)

      IO.puts("tasks: seeded #{length(@dependency_chains)} dependency edges")
    else
      IO.puts("skipping task dependencies — already has data")
    end
  end

  # -- owners ------------------------------------------------------------------------
  defp owned_by(user_id), do: %{owner_id: user_id, owner_shared: false}
  defp shared_owner, do: %{owner_shared: true}
  defp no_owner, do: %{owner_shared: false}

  # -- deadlines ---------------------------------------------------------------------
  defp fixed_deadline(date), do: %{deadline_kind: :fixed, deadline_date: date}
  defp no_deadline, do: %{deadline_kind: :none}

  defp relative_deadline(amount, unit, direction, event) do
    %{
      deadline_kind: :relative,
      deadline_amount: amount,
      deadline_unit: unit,
      deadline_direction: direction,
      deadline_event_id: event.id
    }
  end

  # -- links -------------------------------------------------------------------------
  defp linked_to_event(event), do: %{link_event_id: event.id}
  defp linked_to_category(category), do: %{link_category_id: category.id}
  defp no_link, do: %{}

  defp tasks(actor_id, second_id, events, categories) do
    today = Date.utc_today()
    civil = Map.fetch!(events, "Civil ceremony")
    church = Map.fetch!(events, "Church ceremony")
    reception = Map.fetch!(events, "Reception")
    dinner = Map.fetch!(events, "Dinner")

    photography = Map.fetch!(categories, "Photography")
    flowers = Map.fetch!(categories, "Flowers")
    catering = Map.fetch!(categories, "Catering")
    venue = Map.fetch!(categories, "Venue")

    [
      # -- overdue (fixed, in the past) ------------------------------------------------
      task(
        "Book photographer",
        :done,
        owned_by(actor_id),
        fixed_deadline(Date.add(today, -60)),
        linked_to_category(photography)
      ),
      task(
        "Choose wedding dress",
        :done,
        owned_by(actor_id),
        fixed_deadline(Date.add(today, -45)),
        no_link()
      ),
      task(
        "Send save-the-dates",
        :in_progress,
        shared_owner(),
        fixed_deadline(Date.add(today, -30)),
        no_link()
      ),
      task(
        "Confirm guest list draft",
        :to_do,
        no_owner(),
        fixed_deadline(Date.add(today, -20)),
        no_link()
      ),
      task(
        "Book florist consultation",
        :to_do,
        owned_by(second_id),
        fixed_deadline(Date.add(today, -10)),
        linked_to_category(flowers)
      ),

      # -- due within the next 7 days --------------------------------------------------
      task(
        "Taste-test catering menu",
        :to_do,
        shared_owner(),
        fixed_deadline(Date.add(today, 3)),
        linked_to_category(catering)
      ),
      task(
        "Finalize seating chart draft",
        :to_do,
        owned_by(actor_id),
        fixed_deadline(Date.add(today, 5)),
        no_link()
      ),
      task(
        "Pay venue deposit",
        :to_do,
        no_owner(),
        fixed_deadline(Date.add(today, 7)),
        linked_to_category(venue)
      ),

      # -- later -------------------------------------------------------------------------
      task(
        "Order wedding rings",
        :to_do,
        owned_by(actor_id),
        fixed_deadline(Date.add(today, 30)),
        no_link()
      ),
      task(
        "Book hair & makeup trial",
        :to_do,
        shared_owner(),
        fixed_deadline(Date.add(today, 60)),
        no_link()
      ),
      task(
        "Print menus",
        :to_do,
        no_owner(),
        fixed_deadline(Date.add(today, 90)),
        no_link()
      ),
      task(
        "Arrange transportation",
        :to_do,
        owned_by(second_id),
        fixed_deadline(Date.add(today, 120)),
        no_link()
      ),
      task(
        "Arrange guest transport to the church",
        :to_do,
        shared_owner(),
        fixed_deadline(Date.add(today, 150)),
        linked_to_event(church)
      ),
      task(
        "Confirm final headcount",
        :to_do,
        shared_owner(),
        fixed_deadline(Date.add(today, 200)),
        linked_to_category(catering)
      ),

      # -- no deadline ---------------------------------------------------------------
      task(
        "Research honeymoon destinations",
        :to_do,
        shared_owner(),
        no_deadline(),
        no_link()
      ),
      task(
        "Write wedding vows",
        :to_do,
        owned_by(actor_id),
        no_deadline(),
        no_link()
      ),
      task(
        "Create wedding website",
        :done,
        shared_owner(),
        no_deadline(),
        no_link()
      ),
      task(
        "Choose wedding favors",
        :to_do,
        no_owner(),
        no_deadline(),
        no_link()
      ),
      task(
        "Plan rehearsal dinner",
        :in_progress,
        owned_by(actor_id),
        no_deadline(),
        no_link()
      ),
      task(
        "Select wedding cake flavor",
        :to_do,
        owned_by(second_id),
        no_deadline(),
        linked_to_category(catering)
      ),

      # -- relative deadlines (TSK-02/03, normative example T4) -----------------------
      task(
        "Send invitations",
        :to_do,
        shared_owner(),
        relative_deadline(12, :weeks, :before, reception),
        no_link()
      ),
      task(
        "Book ceremony musician",
        :to_do,
        owned_by(actor_id),
        relative_deadline(4, :weeks, :before, civil),
        linked_to_event(civil)
      ),
      task(
        "Confirm dinner headcount with caterer",
        :to_do,
        no_owner(),
        relative_deadline(1, :weeks, :before, dinner),
        linked_to_category(catering)
      )
    ]
  end

  defp task(title, status, owner, deadline, link) do
    %{title: title, status: status}
    |> Map.merge(owner)
    |> Map.merge(deadline)
    |> Map.merge(link)
  end
end
