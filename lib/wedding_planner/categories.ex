defmodule WeddingPlanner.Categories do
  @moduledoc """
  Cost categories and their services (`docs/modules/offers-and-comparison.md`
  §Categories and services — `CST-01` through `CST-06`; `docs/03-domain-model.md`'s
  Category and Service entities), resources `:category` and `:service`, entity types
  `"category"` and `"service"`.

  This is slice C1's data layer only: schemas, migrations, and a context with rename,
  reorder, re-prioritise, merge and a guarded delete for both categories and services —
  the rows of every future comparison matrix (slice C4). Offers, offer lines, overrides,
  the planning pick and the budget use of a category's target are all later C/B slices;
  nothing here reads or writes any of that. The screens are task 29.

  ## Manual sort order (`CST-01`)

  `list_categories/0` and `list_services/1` are the only supported read orders:
  `sort_order`, then `id` as a stable tiebreak — the same `WeddingPlanner.Events`
  pattern. Services are ordered **within their own category**; `move_service/3` never
  reorders across categories.

  ## Category deletion (`DR-26` Q11)

  `docs/` has no rule for deleting a category on its own — only `D-34`'s protection of a
  service with priced offer lines. `DR-26` settled Q11: a category can be deleted only
  when it has no offers and no invoices (`category_deletion_blockers/1`). Slice C2 wired
  in the offers half (`WeddingPlanner.Offers.count_offers/1`); invoices (slice B2) do not
  exist yet, so only that half of the guard can ever fire today — B2 extends this
  function rather than re-deciding it. Deleting a
  category removes every one of its services with it (the `services.category_id`
  foreign key is `on_delete: :restrict`, so this module deletes them explicitly, one
  `Log.entry/3` per service, inside the same `Log.action/3` as the category's own
  deletion — see `delete_category/2`). `category_deletion_effects/1` is what the
  confirmation shows beforehand.

  ## Service deletion (`CST-06`, `D-34`, `DR-26` Q12 — the C1/C2 split)

  A service with no offer lines is deleted after a plain confirmation. A service that
  **has** offer lines MUST NOT be deleted: the confirmation instead offers **merge into
  another service** (`CST-04`) or **set its wanted priority to *not wanted***. Slice C2
  (offers and offer lines) does not exist yet, so `service_line_count/1` always returns
  `0` in this slice — meaning `delete_service/2`'s "has lines" branch below can never be
  exercised with real data yet, only through the test seam it documents. This is a
  deliberate DR-5/DR-8-style split, tracked here and in slice C2's own task: **slice C2
  MUST replace `service_line_count/1`'s body** with a real count of the service's offer
  lines and add the tests that exercise `{:error, :has_lines}` for real. Until then,
  tests reach that branch via

      Application.put_env(:wedding_planner, :service_line_count_fun, fn _service -> 3 end)
      on_exit(fn -> Application.delete_env(:wedding_planner, :service_line_count_fun) end)

  mirroring `WeddingPlanner.Events.affected_references/1`'s provider-config seam —
  `service_line_count/1` reads `:service_line_count_fun` from application config,
  defaulting to a function that always returns `0`.

  ## Merge (`CST-04`, `DR-26` Q14)

  `merge_services/3` requires both services to be in the same category
  (`{:error, :different_categories}` otherwise). The user picks the survivor: it keeps
  **its own** name, wanted priority and position; the absorbed service is deleted (its
  history remains, its log link degrades to text — same as any other deleted entity,
  `WeddingPlanner.Log.EntityRef`). In this slice there is nothing else to move — no
  offer lines, overrides or frozen selections exist yet — so the function body is just
  the absorbed service's deletion plus the log. It is written as one
  `WeddingPlanner.Log.action/3` specifically so slices C2 (offer lines), C3/C4
  (per-offer overrides) and C5 (frozen selections) can add their own moves **inside the
  same transaction**, before the absorbed service is deleted — see the clearly marked
  comment at that point in `merge_services/3`.

  Service names are unique within a category, case-insensitively and Unicode-aware
  (`String.downcase/1` — SQLite's `lower()` folds ASCII only, so the database's matching
  unique index is only a backstop). `validate_name_unique_in_category/3` is the query
  this needs, applied by `change_service/2` so a rename to an existing name in the same
  category fails with a changeset error naming the clashing service — a screen can then
  offer "merge instead".

  ## Money (`CST-01`'s target field)

  `target` is stored via `Money.Ecto.Map.Type` (`NFR-10`); no money arithmetic happens
  in SQL (`NFR-13`). `%Money{}` is only ever constructed via `WeddingPlanner.Money.new/2`
  from a `Decimal` or integer (`DR-18`) — user input goes through
  `WeddingPlanner.Money.parse/1` (`DR-23`), via `Categories.Category`'s virtual
  `target_input` field. See that schema's moduledoc for the exact "explicit empty clears,
  omitted leaves untouched" contract, copied from `WeddingPlanner.Settings`.

  ## Activity log (`XC-10`) and PubSub (`XC-01`, `XC-02`)

  Every mutation writes through `WeddingPlanner.Log` and broadcasts the whole resulting
  record via `WeddingPlanner.Realtime` (resources `:category` and `:service`) only
  after its write succeeds. `move_category/3`, `move_service/3`, `delete_category/2` and
  `merge_services/3` each touch more than one row, so each goes through `Log.action/3`
  (one summarising entry plus one child entry per affected row, `XC-12`) rather than
  independent `Log.entry/3` calls — see `WeddingPlanner.Log`'s moduledoc for why. Per
  `DR-21`/`XC-02` there is no concurrent-edit indicator of any kind.

  ## Activity-log links (`XC-10`)

  `resolve_category_log_entity/1` and `resolve_service_log_entity/1` are the resolver
  functions `WeddingPlanner.Log.EntityRef.default_resolvers/0` points at for the
  `"category"` and `"service"` entity types. A category resolves to its own name and
  `/categories/<id>`; a service has no page of its own, so it resolves to
  `"<service name> (<category name>)"` and its category's `/categories/<category_id>`
  page. Both degrade to plain text once deleted — including a service that was merged
  away, which is simply a delete from this module's point of view.
  """

  import Ecto.Query

  alias WeddingPlanner.Accounts.Scope
  alias WeddingPlanner.Accounts.User
  alias WeddingPlanner.Categories.Category
  alias WeddingPlanner.Categories.Service
  alias WeddingPlanner.Log
  alias WeddingPlanner.Offers
  alias WeddingPlanner.Realtime
  alias WeddingPlanner.Repo
  alias WeddingPlanner.Tasks
  alias WeddingPlannerWeb.Format

  @category_resource :category
  @service_resource :service

  @category_loggable_fields [:name, :target]
  @service_loggable_fields [:name, :wanted_priority]

  # -- Categories --------------------------------------------------------------------

  @doc "`CST-01`: every category, in manual sort order — `sort_order`, then `id`."
  @spec list_categories() :: [Category.t()]
  def list_categories do
    Category
    |> order_by([c], asc: c.sort_order, asc: c.id)
    |> Repo.all()
  end

  @doc "Fetches one category by id. Raises `Ecto.NoResultsError` if it does not exist."
  @spec get_category!(term()) :: Category.t()
  def get_category!(id), do: Repo.get!(Category, id)

  @doc """
  A changeset for building/validating a category form (create or edit) — never persists
  on its own.
  """
  @spec change_category(Category.t(), map()) :: Ecto.Changeset.t()
  def change_category(%Category{} = category, attrs \\ %{}),
    do: Category.changeset(category, attrs)

  @doc """
  Creates a category, appended after the current last one (`CST-01` — new categories
  never reorder existing ones), logs the create (`XC-10`) and broadcasts
  `{:created, category}` (`XC-01`).
  """
  @spec create_category(Scope.t(), map()) :: {:ok, Category.t()} | {:error, Ecto.Changeset.t()}
  def create_category(%Scope{} = scope, attrs) do
    %Category{sort_order: next_category_sort_order()}
    |> change_category(attrs)
    |> Repo.insert()
    |> case do
      {:ok, category} ->
        {:ok, _} =
          Log.entry(
            scope,
            {:category, category.id},
            "#{actor(scope)} created category '#{category.name}'"
          )

        Realtime.broadcast_change(@category_resource, {:created, category})
        {:ok, category}

      error ->
        error
    end
  end

  @doc """
  Updates a category's name and/or target. Logs one activity entry per user-facing field
  that actually changed (`XC-10`), e.g. "Wannes changed the target of 'Venue': Not set →
  € 2.500,00" — the target's old/new values go through `WeddingPlannerWeb.Format.money/1`
  the same way the UI displays them. Broadcasts `{:updated, category}` (`XC-01`) once,
  after every log entry is written.
  """
  @spec update_category(Scope.t(), Category.t(), map()) ::
          {:ok, Category.t()} | {:error, Ecto.Changeset.t()}
  def update_category(%Scope{} = scope, %Category{} = category, attrs) do
    changeset = change_category(category, attrs)

    with {:ok, updated} <- Repo.update(changeset) do
      :ok = log_category_changes(scope, category, updated, changeset)
      Realtime.broadcast_change(@category_resource, {:updated, updated})
      {:ok, updated}
    end
  end

  @doc """
  `CST-01`: moves `category` one position `:up` or `:down` in the manual sort order,
  swapping `sort_order` with its neighbour. A no-op at either end of the list. Logged as
  one `Log.action/3` summary plus one child entry per affected category (`XC-12`), same
  pattern as `WeddingPlanner.Events.move_event/3`. Race-safe per `XC-02`.
  """
  @spec move_category(Scope.t(), Category.t(), :up | :down) :: :ok
  def move_category(%Scope{} = scope, %Category{} = category, direction)
      when direction in [:up, :down] do
    categories = list_categories()

    case neighbor(categories, category, direction) do
      :boundary ->
        :ok

      {:ok, neighbor} ->
        {:ok, {moved, moved_neighbor}} =
          Log.action(
            scope,
            "#{actor(scope)} moved '#{category.name}' #{direction_word(direction)} in the category order",
            fn -> swap_categories_and_log(scope, category, neighbor, direction) end
          )

        Realtime.broadcast_change(@category_resource, {:updated, moved})
        Realtime.broadcast_change(@category_resource, {:updated, moved_neighbor})
        :ok
    end
  end

  @doc """
  `DR-26` Q11: the reasons `category` cannot yet be deleted — a category can be deleted
  only when it has no offers and no invoices. Counts offers today (`[%{label: "3
  offers", count: 3}]`, singular "1 offer"); slice B2 (invoices) adds its own check here
  once that table exists. Any non-empty result means `delete_category/2` must refuse. A
  task **linked** to this category (task 32, `DR-26` Q18) is never a blocker — like a
  task linked to an event (`WeddingPlanner.Events`), the link is simply cleared and
  logged; see `category_deletion_effects/1` and `delete_category/2`.
  """
  @spec category_deletion_blockers(Category.t()) :: [%{label: String.t(), count: pos_integer()}]
  def category_deletion_blockers(%Category{} = category) do
    case Offers.count_offers(category) do
      0 -> []
      n -> [%{label: "#{n} #{pluralize(n, "offer")}", count: n}]
    end
  end

  @doc """
  `DR-26` Q11/Q18: what deleting `category` would remove, for the deletion
  confirmation (`XC-40`) — its services, always, as a `[%{label: "5 services", count:
  5}]`-style entry, plus a task-link entry (`WeddingPlanner.Tasks.category_link_reference/1`)
  when any task links to this category, exactly like `WeddingPlanner.Events.affected_references/1`
  does for events. Task links are never a deletion **blocker** (`DR-26` Q11) — only an
  effect, cleared and logged by `delete_category/2` below.
  """
  @spec category_deletion_effects(Category.t()) :: [
          %{label: String.t(), count: non_neg_integer()}
        ]
  def category_deletion_effects(%Category{} = category) do
    n = count_services(category)
    services_entry = %{label: "#{n} #{pluralize(n, "service")}", count: n}

    case Tasks.category_link_reference(category) do
      nil -> [services_entry]
      task_entry -> [services_entry, task_entry]
    end
  end

  @doc """
  Deletes `category` and every one of its services (`DR-26` Q11), refusing with
  `{:error, :has_blockers}` when `category_deletion_blockers/1` returns anything.
  Otherwise, one `Log.action/3`: a summary ("Wannes deleted category 'Venue' (5
  services)"), a child entry per service deleted, `WeddingPlanner.Tasks.detach_category/2`
  clearing and logging any task link (`DR-26` Q18, same "clear + log, not a blocker"
  treatment as an event link — see `WeddingPlanner.Tasks`' moduledoc), then the
  category's own entry — matching `services.category_id`'s `on_delete: :restrict`
  (services must be deleted first) and `tasks.link_category_id`'s `on_delete: :restrict`
  (task links must be cleared first), each explicit deletion/clear logged (`XC-10`,
  `XC-12`). Broadcasts `{:deleted, id}` for every deleted service, `{:updated, task}` for
  every detached task, and `{:deleted, id}` for the category itself (`XC-01`) — all only
  after the transaction commits.
  """
  @spec delete_category(Scope.t(), Category.t()) :: {:ok, Category.t()} | {:error, :has_blockers}
  def delete_category(%Scope{} = scope, %Category{} = category) do
    if category_deletion_blockers(category) == [] do
      services = list_services(category)
      count = length(services)

      {:ok, {deleted, detached_tasks}} =
        Log.action(
          scope,
          "#{actor(scope)} deleted category '#{category.name}' (#{count} #{pluralize(count, "service")})",
          fn -> delete_category_and_services(scope, category, services) end
        )

      Enum.each(services, &Realtime.broadcast_change(@service_resource, {:deleted, &1.id}))
      Enum.each(detached_tasks, &Realtime.broadcast_change(:task, {:updated, &1}))
      Realtime.broadcast_change(@category_resource, {:deleted, deleted.id})
      {:ok, deleted}
    else
      {:error, :has_blockers}
    end
  end

  # -- Services ------------------------------------------------------------------------

  @doc "A category's services, in manual sort order — `sort_order`, then `id` (`CST-02`)."
  @spec list_services(Category.t() | term()) :: [Service.t()]
  def list_services(%Category{id: category_id}), do: list_services(category_id)

  def list_services(category_id) do
    Service
    |> where([s], s.category_id == ^category_id)
    |> order_by([s], asc: s.sort_order, asc: s.id)
    |> Repo.all()
  end

  @doc "Fetches one service by id. Raises `Ecto.NoResultsError` if it does not exist."
  @spec get_service!(term()) :: Service.t()
  def get_service!(id), do: Repo.get!(Service, id)

  @doc """
  A changeset for building/validating a service form (create or edit) — never persists
  on its own. Includes the `CST-04`/`DR-26` Q14 name-uniqueness check (needs a query, so
  it is not in `Service.changeset/2` alone), so a live form shows that error too, not
  only a submit-time one. `service.category_id` MUST already be set (either the
  persisted category, or set on a fresh `%Service{}` before calling this).
  """
  @spec change_service(Service.t(), map()) :: Ecto.Changeset.t()
  def change_service(%Service{} = service, attrs \\ %{}) do
    service
    |> Service.changeset(attrs)
    |> validate_name_unique_in_category(service.category_id, service.id)
  end

  @doc """
  Creates a service in `category`, appended after its current last service (`CST-02` —
  "created on the fly while entering offers" is the same appended-last, never-castable
  `sort_order` pattern as everywhere else in this module). Logs the create (`XC-10`) and
  broadcasts `{:created, service}` (`XC-01`). Rejects a name clash within the category
  (`CST-04`, `DR-26` Q14).
  """
  @spec create_service(Scope.t(), Category.t(), map()) ::
          {:ok, Service.t()} | {:error, Ecto.Changeset.t()}
  def create_service(%Scope{} = scope, %Category{} = category, attrs) do
    %Service{category_id: category.id, sort_order: next_service_sort_order(category)}
    |> change_service(attrs)
    |> Repo.insert()
    |> case do
      {:ok, service} ->
        {:ok, _} =
          Log.entry(
            scope,
            {:service, service.id},
            "#{actor(scope)} created service '#{service.name}' in '#{category.name}'"
          )

        Realtime.broadcast_change(@service_resource, {:created, service})
        {:ok, service}

      error ->
        error
    end
  end

  @doc """
  Renames a service and/or changes its wanted priority (`CST-03`, `CST-04`). Logs one
  activity entry per changed field (`XC-10`), e.g. "Wannes changed the wanted priority
  of 'Catering' in Venue: Nice-to-have → Must-have". A rename to an existing name in the
  same category fails with a changeset error naming the clashing service, so a screen
  can offer "merge instead" (`DR-26` Q14). Broadcasts `{:updated, service}` (`XC-01`)
  once, after every log entry is written.
  """
  @spec update_service(Scope.t(), Service.t(), map()) ::
          {:ok, Service.t()} | {:error, Ecto.Changeset.t()}
  def update_service(%Scope{} = scope, %Service{} = service, attrs) do
    changeset = change_service(service, attrs)

    with {:ok, updated} <- Repo.update(changeset) do
      :ok = log_service_changes(scope, service, updated, changeset)
      Realtime.broadcast_change(@service_resource, {:updated, updated})
      {:ok, updated}
    end
  end

  @doc """
  `CST-02`: moves `service` one position `:up` or `:down` within its own category's
  manual sort order — never across categories. A no-op at either end of the category's
  list. Logged as one `Log.action/3` summary plus one child entry per affected service
  (`XC-12`). Race-safe per `XC-02`.
  """
  @spec move_service(Scope.t(), Service.t(), :up | :down) :: :ok
  def move_service(%Scope{} = scope, %Service{} = service, direction)
      when direction in [:up, :down] do
    services = list_services(service.category_id)

    case neighbor(services, service, direction) do
      :boundary ->
        :ok

      {:ok, neighbor} ->
        category_name = category_name(service.category_id)

        {:ok, {moved, moved_neighbor}} =
          Log.action(
            scope,
            "#{actor(scope)} moved '#{service.name}' #{direction_word(direction)} in #{category_name}",
            fn -> swap_services_and_log(scope, service, neighbor, category_name, direction) end
          )

        Realtime.broadcast_change(@service_resource, {:updated, moved})
        Realtime.broadcast_change(@service_resource, {:updated, moved_neighbor})
        :ok
    end
  end

  @doc """
  `DR-26` Q12: how many offer lines reference `service` — see this module's "Service
  deletion" moduledoc section for the full split. Reads
  `Application.get_env(:wedding_planner, :service_line_count_fun)`, defaulting to a
  function that always returns `0` (no offer line schema exists yet in this slice, so no
  service can truthfully have any). **Slice C2 replaces the default with a real
  count-of-offer-lines query** (and adds the tests that exercise the resulting
  `{:error, :has_lines}` branch of `delete_service/2` for real); until then, this is also
  the test seam this slice's own tests use to exercise that branch.
  """
  @spec service_line_count(Service.t()) :: non_neg_integer()
  def service_line_count(%Service{} = service) do
    fun = Application.get_env(:wedding_planner, :service_line_count_fun, fn _service -> 0 end)
    fun.(service)
  end

  @doc """
  `CST-06`, `D-34`: deletes `service` after a plain confirmation, logging the delete
  (`XC-10`) and broadcasting `{:deleted, id}` (`XC-01`) — but only when
  `service_line_count/1` is `0`. When it is greater than `0`, refuses with
  `{:error, :has_lines}` and deletes nothing: the caller then offers merge
  (`merge_services/3`) or setting the wanted priority to `:not_wanted` instead.
  """
  @spec delete_service(Scope.t(), Service.t()) :: {:ok, Service.t()} | {:error, :has_lines}
  def delete_service(%Scope{} = scope, %Service{} = service) do
    if service_line_count(service) > 0 do
      {:error, :has_lines}
    else
      {:ok, deleted} = Repo.delete(service)

      {:ok, _} =
        Log.entry(
          scope,
          {:service, deleted.id},
          "#{actor(scope)} deleted service '#{deleted.name}'"
        )

      Realtime.broadcast_change(@service_resource, {:deleted, deleted.id})
      {:ok, deleted}
    end
  end

  @doc """
  `CST-04`, `DR-26` Q14: merges `absorbed` into `survivor`. Both MUST be in the same
  category (`{:error, :different_categories}` otherwise). The survivor keeps its own
  name, wanted priority and position; `absorbed` is deleted. One `Log.action/3`:
  a summary ("Wannes merged 'Sound system' into 'Sound' in Venue"), a child entry on the
  survivor and one on the absorbed service, then the absorbed service is deleted.
  Broadcasts `{:deleted, id}` for the absorbed service (`XC-01`) — the survivor's own row
  is not modified by this slice, so nothing about it is broadcast.

  In this slice there is nothing else to move (no offer lines, overrides or frozen
  selections exist yet) — see the comment at that point below for where later slices
  add their own moves, inside this same transaction, before the absorbed service is
  deleted.
  """
  @spec merge_services(Scope.t(), Service.t(), Service.t()) ::
          {:ok, Service.t()} | {:error, :different_categories}
  def merge_services(%Scope{} = scope, %Service{} = absorbed, %Service{} = survivor) do
    if absorbed.category_id == survivor.category_id do
      category_name = category_name(survivor.category_id)

      {:ok, deleted} =
        Log.action(
          scope,
          "#{actor(scope)} merged '#{absorbed.name}' into '#{survivor.name}' in #{category_name}",
          fn -> merge_and_log(scope, absorbed, survivor, category_name) end
        )

      Realtime.broadcast_change(@service_resource, {:deleted, deleted.id})
      {:ok, survivor}
    else
      {:error, :different_categories}
    end
  end

  @doc """
  `WeddingPlanner.Log.EntityRef` resolver for the `"category"` entity type: an existing
  category resolves to its name and `/categories/<id>`; a deleted one is `:error`
  (degrades to plain text).
  """
  @spec resolve_category_log_entity(term()) :: {:ok, String.t(), String.t() | nil} | :error
  def resolve_category_log_entity(id) do
    case Repo.get(Category, id) do
      nil -> :error
      category -> {:ok, category.name, "/categories/#{category.id}"}
    end
  end

  @doc """
  `WeddingPlanner.Log.EntityRef` resolver for the `"service"` entity type: an existing
  service resolves to `"<name> (<category name>)"` and its category's
  `/categories/<category_id>` page (a service has no page of its own). A deleted service
  — including one that was merged away — is `:error` (degrades to plain text).
  """
  @spec resolve_service_log_entity(term()) :: {:ok, String.t(), String.t() | nil} | :error
  def resolve_service_log_entity(id) do
    case Repo.get(Service, id) do
      nil ->
        :error

      service ->
        {:ok, "#{service.name} (#{category_name(service.category_id)})",
         "/categories/#{service.category_id}"}
    end
  end

  # -- private ---------------------------------------------------------------

  defp delete_category_and_services(scope, category, services) do
    Enum.each(services, fn service ->
      {:ok, _} = Repo.delete(service)

      {:ok, _} =
        Log.entry(
          scope,
          {:service, service.id},
          "#{actor(scope)} deleted service '#{service.name}' (category '#{category.name}' deleted)"
        )
    end)

    # `DR-26` Q18: clear (and log) any task's link to this category *before* the
    # category row is deleted — `tasks.link_category_id`'s `on_delete: :restrict` would
    # otherwise block the delete below.
    detached_tasks = Tasks.detach_category(scope, category)

    {:ok, deleted} = Repo.delete(category)

    {:ok, _} =
      Log.entry(
        scope,
        {:category, deleted.id},
        "#{actor(scope)} deleted category '#{deleted.name}'"
      )

    {deleted, detached_tasks}
  end

  defp merge_and_log(scope, absorbed, survivor, category_name) do
    # C2/C3/C4/C5 add their own moves here, inside this same transaction, *before* the
    # absorbed service is deleted below: offer lines (C2), per-offer overrides (C3/C4),
    # frozen selections (C5) all move from `absorbed` to `survivor`.

    {:ok, _} =
      Log.entry(
        scope,
        {:service, survivor.id},
        "#{actor(scope)} merged '#{absorbed.name}' into '#{survivor.name}' in #{category_name}"
      )

    {:ok, _} =
      Log.entry(
        scope,
        {:service, absorbed.id},
        "#{actor(scope)} merged '#{absorbed.name}' into '#{survivor.name}' in #{category_name}"
      )

    {:ok, deleted} = Repo.delete(absorbed)
    deleted
  end

  defp next_category_sort_order do
    case Repo.aggregate(Category, :max, :sort_order) do
      nil -> 0
      max -> max + 1
    end
  end

  defp next_service_sort_order(%Category{id: category_id}) do
    max =
      Service
      |> where([s], s.category_id == ^category_id)
      |> Repo.aggregate(:max, :sort_order)

    case max do
      nil -> 0
      max -> max + 1
    end
  end

  defp count_services(%Category{id: category_id}) do
    Service
    |> where([s], s.category_id == ^category_id)
    |> Repo.aggregate(:count)
  end

  defp category_name(category_id), do: Repo.get!(Category, category_id).name

  # `CST-04`/`DR-26` Q14: case-insensitive, Unicode-aware (`String.downcase/1` — never
  # SQLite's ASCII-only `lower()`) uniqueness within one category. `exclude_id` leaves
  # the service itself (an update) or nothing (a brand-new service) out of the clash
  # check.
  defp validate_name_unique_in_category(changeset, category_id, exclude_id) do
    case Ecto.Changeset.get_change(changeset, :name) do
      nil ->
        changeset

      name ->
        normalized = String.downcase(name)

        clashing =
          Service
          |> where([s], s.category_id == ^category_id)
          |> exclude_id(exclude_id)
          |> Repo.all()
          |> Enum.find(&(String.downcase(&1.name) == normalized))

        case clashing do
          nil ->
            changeset

          %Service{name: clashing_name} ->
            Ecto.Changeset.add_error(
              changeset,
              :name,
              "is already used by '#{clashing_name}' in this category — merge instead?"
            )
        end
    end
  end

  defp exclude_id(query, nil), do: query
  defp exclude_id(query, id), do: where(query, [s], s.id != ^id)

  defp neighbor(items, %{id: id}, :up) do
    case Enum.find_index(items, &(&1.id == id)) do
      nil -> :boundary
      0 -> :boundary
      idx -> {:ok, Enum.at(items, idx - 1)}
    end
  end

  defp neighbor(items, %{id: id}, :down) do
    last_index = length(items) - 1

    case Enum.find_index(items, &(&1.id == id)) do
      nil -> :boundary
      ^last_index -> :boundary
      idx -> {:ok, Enum.at(items, idx + 1)}
    end
  end

  defp swap_categories_and_log(scope, category, neighbor, direction) do
    {:ok, moved} = category |> Category.sort_order_changeset(neighbor.sort_order) |> Repo.update()

    {:ok, moved_neighbor} =
      neighbor |> Category.sort_order_changeset(category.sort_order) |> Repo.update()

    {:ok, _} =
      Log.entry(
        scope,
        {:category, moved.id},
        "#{actor(scope)} moved '#{moved.name}' #{direction_word(direction)}"
      )

    {:ok, _} =
      Log.entry(
        scope,
        {:category, moved_neighbor.id},
        "#{actor(scope)} moved '#{moved_neighbor.name}' #{direction_word(opposite(direction))} (swapped with '#{moved.name}')"
      )

    {moved, moved_neighbor}
  end

  defp swap_services_and_log(scope, service, neighbor, category_name, direction) do
    {:ok, moved} = service |> Service.sort_order_changeset(neighbor.sort_order) |> Repo.update()

    {:ok, moved_neighbor} =
      neighbor |> Service.sort_order_changeset(service.sort_order) |> Repo.update()

    {:ok, _} =
      Log.entry(
        scope,
        {:service, moved.id},
        "#{actor(scope)} moved '#{moved.name}' #{direction_word(direction)} in #{category_name}"
      )

    {:ok, _} =
      Log.entry(
        scope,
        {:service, moved_neighbor.id},
        "#{actor(scope)} moved '#{moved_neighbor.name}' #{direction_word(opposite(direction))} in #{category_name} (swapped with '#{moved.name}')"
      )

    {moved, moved_neighbor}
  end

  defp direction_word(:up), do: "up"
  defp direction_word(:down), do: "down"

  defp opposite(:up), do: :down
  defp opposite(:down), do: :up

  defp pluralize(1, word), do: word
  defp pluralize(_n, word), do: word <> "s"

  defp log_category_changes(scope, %Category{} = before, %Category{} = updated, changeset) do
    changeset.changes
    |> Map.keys()
    |> Enum.filter(&(&1 in @category_loggable_fields))
    |> Enum.each(fn field ->
      old = category_display_value(field, Map.fetch!(before, field))
      new = category_display_value(field, Map.fetch!(updated, field))

      {:ok, _} =
        Log.entry(
          scope,
          {:category, updated.id},
          "#{actor(scope)} changed the #{field} of '#{before.name}': #{old} → #{new}"
        )
    end)

    :ok
  end

  defp category_display_value(:target, nil), do: "Not set"
  defp category_display_value(:target, %Money{} = money), do: Format.money(money)
  defp category_display_value(_field, value), do: value

  defp log_service_changes(scope, %Service{} = before, %Service{} = updated, changeset) do
    category_name = category_name(before.category_id)

    changeset.changes
    |> Map.keys()
    |> Enum.filter(&(&1 in @service_loggable_fields))
    |> Enum.each(fn field ->
      old = service_display_value(field, Map.fetch!(before, field))
      new = service_display_value(field, Map.fetch!(updated, field))

      {:ok, _} =
        Log.entry(
          scope,
          {:service, updated.id},
          "#{actor(scope)} changed the #{field_label(field)} of '#{before.name}' in #{category_name}: #{old} → #{new}"
        )
    end)

    :ok
  end

  defp field_label(:wanted_priority), do: "wanted priority"
  defp field_label(field), do: to_string(field)

  defp service_display_value(:wanted_priority, value), do: wanted_priority_label(value)
  defp service_display_value(_field, value), do: value

  defp wanted_priority_label(:not_wanted), do: "Not wanted"
  defp wanted_priority_label(:nice_to_have), do: "Nice-to-have"
  defp wanted_priority_label(:must_have), do: "Must-have"

  defp actor(%Scope{user: %User{display_name: name}}), do: name
end
