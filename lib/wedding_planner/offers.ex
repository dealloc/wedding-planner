defmodule WeddingPlanner.Offers do
  @moduledoc """
  Offers within a category (`docs/modules/offers-and-comparison.md` `CST-10`, `CST-33`,
  `CST-36`; `DR-40`), resource `:offer`, entity type `"offer"`, and their lines
  (`CST-11`, `CST-20` through `CST-33`; `DR-41`, `DR-42`), resource `:offer_line`. This is
  slice C2's data layer only; the screens are tasks 51 and 52. Nothing here computes a
  total, a gap or a formula — that is slice C3/C4 (`DR-43`): the lines stored here are the
  C3 engine's inputs, stored exactly as entered.

  ## References (`DR-28`, `XC-20`–`XC-24`)

  `reference_owner/1` is the `WeddingPlanner.References.Owner` C2 promised B1:
  `%{attrs: %{offer_id: offer.id}, log_entity: {:offer, offer.id}, name: "offer
  '<vendor>'"}`. `delete_offer/2` follows the two-step contract
  `WeddingPlanner.References` documents: `References.delete_owner_references/2` runs
  **inside** the offer's own `Log.action/3`, before the offer row is deleted (the
  `references.offer_id` FK is `on_delete: :restrict`, so the references must go first);
  `References.purge_deleted/1` runs **after** the transaction commits.
  `offer_deletion_effects/1` feeds the deletion confirmation (`XC-40`): the offer's line
  count ("5 lines"), its overrides, `References.reference_deletion_effects/1` under the
  offer's owner, then a task-link entry (`DR-8`/`DR-69`, see "Seams into other
  contexts" below) when any task links to this offer.

  ## Category existence (`DR-40`)

  `category_id` is set **programmatically** from an already-loaded `Category` — never
  cast (see `WeddingPlanner.Offers.Offer.changeset/2`). `Ecto.Changeset.foreign_key_constraint/2`
  cannot turn a violation into a changeset error on this project's SQLite adapter (it
  never reports which constraint failed — the same limitation `WeddingPlanner.Guests`'
  `group_id` check and `WeddingPlanner.Tasks`' owner checks document), so `change_offer/2`
  adds the real check itself (`Repo.exists?/1`) rather than relying on the FK. In
  practice this only matters for the rare race where a category is deleted in the
  instant between a form render and its submit — once an offer exists,
  `Categories.category_deletion_blockers/1` refuses to delete its category at all.

  ## Activity log (`XC-10`) and PubSub (`XC-01`)

  Every mutation writes through `WeddingPlanner.Log` and broadcasts the whole resulting
  record via `WeddingPlanner.Realtime` (resource `:offer`) only after its write
  succeeds, same convention as `WeddingPlanner.Categories`. `update_offer/3` logs one
  entry per user-facing field that actually changed — vendor, URL, notes, status, VAT
  basis, VAT rate, minimum spend — money through `WeddingPlannerWeb.Format.money/1`,
  the rate through `WeddingPlanner.Offers.VatRate.format/1`, an unset value as "none".
  `delete_offer/2` is one `Log.action/3`: a summary ("Wannes deleted offer 'Kasteel
  Heers'") whose children are the line removals and the reference removals.

  ## Offer lines (`DR-41`)

  `WeddingPlanner.Offers.OfferLine` holds the structural rules; `change_line/2` adds the
  checks that need a query: the offer exists, the line's service belongs to the offer's
  category, its event exists, and a line VAT rate is only **set** while the offer is VAT
  exclusive (a rate set earlier is retained, and ignored by C3, if the offer later turns
  inclusive — `CST-36` step 5). `list_lines/1` is the only read order: service lines in
  the category's service order (`services.sort_order`, then id), then ad hoc lines by id.

  Line entries are written against the **offer** (`{:offer, id}`), naming the line by
  `line_label/1`: "Wannes added line 'Catering (per adult, Dinner)' to offer 'Venue A'",
  one "changed the amount of line … in offer …: € 85,00 → € 90,00" per changed field
  (money through `WeddingPlannerWeb.Format.money/1`, rates through `VatRate.format/1`,
  unset as "none"), "deleted line 'Cleaning fee' from offer 'Venue A'", and
  "turned on 'Corkage fee' in offer 'Venue A'" for the `CST-22` toggle. Broadcasts carry
  the whole line, `:service` and `:event` preloaded; deletes carry `{:deleted, id}`.

  `create_simple_offer/3` is `CST-11`'s quick offer: one `Log.action/3` creating the offer
  and its single mandatory flat ad hoc line labelled "Price".

  ## Seams into other contexts

    * `count_service_lines/1` is `WeddingPlanner.Categories.service_line_count/1`
      (`CST-06`); `move_service_lines/3` runs inside `Categories.merge_services/3`'s
      `Log.action/3` (`CST-04`), one child entry per affected offer.
    * `detach_event/2` runs inside `WeddingPlanner.Events.delete_event/2`'s
      `Log.action/3` (`XC-41`, `DR-42`): each line referencing the event loses it and so
      becomes invalid (`OfferLine.invalid?/1`), one child entry per line.
      `event_offer_line_reference/1` is the `EVT-05` provider the delete confirmation
      lists — registered in `config :wedding_planner, event_reference_providers:`.
    * `delete_service_overrides/2` runs inside `WeddingPlanner.Categories.delete_service/2`'s
      `Log.action/3` (`CST-24`, `CST-52`, `DR-56`) when the service has overrides, one
      child entry per affected offer; `move_service_overrides/3` runs inside
      `Categories.merge_services/3`'s `Log.action/3`, next to `move_service_lines/3`.
    * `delete_offer/2` calls `WeddingPlanner.Tasks.detach_offer/2` (`DR-8`/`DR-69`, task
      78) inside its own `Log.action/3`, before the offer row is deleted —
      `tasks.link_offer_id`'s `on_delete: :restrict` would otherwise refuse the delete;
      `offer_deletion_effects/1` appends `Tasks.offer_link_reference/1`'s entry
      ("2 tasks linked to this offer (link removed)") when any task links to this offer.
      Never a deletion blocker (`DR-26` Q11's precedent), only an effect.

  ## Overrides (`CST-24`, `CST-52`, `DR-49`, `DR-56`)

  `WeddingPlanner.Offers.Override` persists `DR-49`'s row shape — `offer_id`,
  `service_id`, `wanted` — that `WeddingPlanner.Valuation.Selection` has read since C3.
  `toggle_override/3` is the only writer: it refuses a service of another category
  (`{:error, :wrong_category}`), reuses `Valuation.Selection.effectively_wanted?/3`
  (the single CST-24 definition — never re-derived here) over a snapshot built from the
  stored row for that one offer × service to find the current effective wanted, then
  flips it. When the flipped value equals what the category priority alone would give
  (the default), the row is **deleted** instead of written, so a toggle never leaves a
  redundant row; otherwise the row is upserted with the flipped value
  (`on_conflict: {:replace, [:wanted, :updated_at]}`, conflict target the unique pair).
  A row that later coincides with the default because the priority changed is **kept**
  — the deviation resumes if the priority moves back; only a further toggle re-derives
  whether to keep, replace or delete it. Overrides on rejected offers are allowed
  (`DR-49`). Entries are written against the **offer**: "Wannes turned off 'Sound' for
  offer 'Venue A' (override)", "Wannes turned on 'Garden ceremony' for offer 'Venue A'
  (override)", "Wannes removed the override on 'Sound' for offer 'Venue A'" (a toggle
  that deletes the row). Broadcasts `{:created | :updated, override}` /
  `{:deleted, id}` on `:override` (`XC-01`) after commit. `delete_offer/2` removes an
  offer's overrides the same way it removes its lines — inside its own `Log.action/3`,
  before the offer row, since `offer_overrides.offer_id` is `on_delete: :restrict` —
  and `offer_deletion_effects/1` lists "N overrides" when any exist.

  ## Confirmation, frozen selection and planning pick (C5 — `CST-40`–`CST-44`, `DR-61`–`DR-67`)

  Only `confirm_offer/2` and `unconfirm_offer/2` move an offer's status to or from
  *confirmed* (`DR-62`; `Offer.changeset/2` refuses it). Confirming freezes the offer's
  effective selection as one `WeddingPlanner.Offers.FrozenService` row per service
  (`Valuation.Selection.freeze/2`, `DR-61`), resource `:frozen_service`
  (`{:created, row}` / `{:deleted, id}`); rows exist only while the offer is confirmed.
  While confirmed, the offer's override rows are dormant (`toggle_override/3` refuses
  `{:error, :confirmed}`) and resume after un-confirming (`DR-64`); its scope only grows
  (`add_to_confirmed_scope/3`, and an optional ad hoc line's own toggle — `CST-43`). Line
  edits on a confirmed offer are logged like any other line edit (`CST-43`).
  Un-confirming is refused while invoices link to the offer (`DR-65`,
  `unconfirm_blockers/1`) and clears *invoicing complete* in the same `UPDATE` (`DR-58`).

  The planning pick (`CST-44`, `DR-66`) is one non-rejected, non-confirmed offer per
  category while the category has no confirmed offer (`category_has_confirmed_offer?/1`):
  `set_planning_pick/2` moves it, `clear_planning_pick/2` clears it, rejecting the pick
  (`update_offer/3`) or confirming any offer of its category clears it. Un-confirming never
  restores it.

  Seams for `WeddingPlanner.Categories` (`CST-04`, `CST-06`, `DR-67`):
  `list_offers_freezing_service/1` (a frozen-in service is never deleted),
  `confirmed_scope_mismatch/2` (a merge that would move a committed total is refused) and
  `move_service_frozen_rows/3` (inside the merge's `Log.action/3`).
  """

  import Ecto.Query

  alias WeddingPlanner.Accounts.Scope
  alias WeddingPlanner.Accounts.User
  alias WeddingPlanner.Categories.Category
  alias WeddingPlanner.Categories.Service
  alias WeddingPlanner.Events.Event
  alias WeddingPlanner.Invoices
  alias WeddingPlanner.Log
  alias WeddingPlanner.Offers.FrozenService
  alias WeddingPlanner.Offers.Offer
  alias WeddingPlanner.Offers.OfferLine
  alias WeddingPlanner.Offers.Override
  alias WeddingPlanner.Offers.VatRate
  alias WeddingPlanner.Realtime
  alias WeddingPlanner.References
  alias WeddingPlanner.References.Owner
  alias WeddingPlanner.Repo
  alias WeddingPlanner.Tasks
  alias WeddingPlanner.Valuation.Selection
  alias WeddingPlanner.Valuation.Snapshot
  alias WeddingPlannerWeb.Format

  @resource :offer
  @line_resource :offer_line
  @override_resource :override
  @frozen_resource :frozen_service
  @line_preloads [:service, :event]

  @loggable_fields [
    :vendor_name,
    :url,
    :notes,
    :status,
    :vat_basis,
    :vat_rate_bp,
    :minimum_spend
  ]

  @line_loggable_fields [
    :service_id,
    :label,
    :variation,
    :notes,
    :state,
    :basis,
    :event_id,
    :amount,
    :included_quantity,
    :minimum_charge,
    :vat_rate_bp,
    :enabled
  ]

  @doc "A category's offers, oldest first (`id`)."
  @spec list_offers(Category.t() | term()) :: [Offer.t()]
  def list_offers(%Category{id: category_id}), do: list_offers(category_id)

  def list_offers(category_id) do
    Offer
    |> where([o], o.category_id == ^category_id)
    |> order_by([o], asc: o.id)
    |> Repo.all()
  end

  @doc "Fetches one offer by id, its category preloaded. Raises `Ecto.NoResultsError` if it does not exist."
  @spec get_offer!(term()) :: Offer.t()
  def get_offer!(id) do
    Offer |> Repo.get!(id) |> Repo.preload(:category)
  end

  @doc """
  A changeset for building/validating an offer form (create or edit) — never persists
  on its own. Adds the `category_id` existence check on top of `Offer.changeset/2`'s
  structural rules (see the moduledoc's "Category existence" section).
  """
  @spec change_offer(Offer.t(), map()) :: Ecto.Changeset.t()
  def change_offer(%Offer{} = offer, attrs \\ %{}) do
    offer
    |> Offer.changeset(attrs)
    |> validate_category_exists()
  end

  @doc """
  Creates an offer in `category` (`CST-10`). Logs "Wannes added offer 'Kasteel Heers' to
  Venue" against `{:offer, offer.id}` (`XC-10`) and broadcasts `{:created, offer}`
  (`XC-01`).
  """
  @spec create_offer(Scope.t(), Category.t(), map()) ::
          {:ok, Offer.t()} | {:error, Ecto.Changeset.t()}
  def create_offer(%Scope{} = scope, %Category{} = category, attrs) do
    %Offer{category_id: category.id}
    |> change_offer(attrs)
    |> Repo.insert()
    |> case do
      {:ok, offer} ->
        {:ok, _} =
          Log.entry(
            scope,
            {:offer, offer.id},
            "#{actor(scope)} added offer '#{offer.vendor_name}' to #{category.name}"
          )

        Realtime.broadcast_change(@resource, {:created, offer})
        {:ok, offer}

      error ->
        error
    end
  end

  @doc """
  Updates an offer's user-facing fields. Logs one activity entry per changed field
  (`XC-10`), e.g. "Wannes changed the status of offer 'Kasteel Heers': considering →
  shortlisted". Broadcasts `{:updated, offer}` (`XC-01`) once, after every log entry is
  written. The status never moves to or from *confirmed* here (`DR-62`, see
  `Offer.changeset/2`).

  Rejecting the category's planning pick (`DR-66`) clears `planning_pick` in the **same**
  `UPDATE` (the `offers_planning_pick_requires_open_status` CHECK) and logs one extra
  entry: "Wannes cleared offer 'Venue B' as the planning pick for Venue (offer rejected)".
  """
  @spec update_offer(Scope.t(), Offer.t(), map()) ::
          {:ok, Offer.t()} | {:error, Ecto.Changeset.t()}
  def update_offer(%Scope{} = scope, %Offer{} = offer, attrs) do
    changeset = offer |> change_offer(attrs) |> clear_pick_on_reject(offer)

    with {:ok, updated} <- Repo.update(changeset) do
      :ok = log_offer_changes(scope, offer, updated, changeset)

      if Ecto.Changeset.get_change(changeset, :planning_pick) == false do
        {:ok, _} =
          Log.entry(
            scope,
            {:offer, updated.id},
            pick_cleared_description(scope, updated, " (offer rejected)")
          )
      end

      Realtime.broadcast_change(@resource, {:updated, updated})
      {:ok, updated}
    end
  end

  @doc """
  Deletes `offer` (`XC-24`, `DR-40`), refusing with `{:error, :has_invoices}` when
  `offer_deletion_blockers/1` returns anything (`DR-58`) — an invoice linked to this offer
  would otherwise be orphaned by a restrict FK error instead of a clean refusal.
  Otherwise, one `Log.action/3` — "Wannes deleted offer 'Kasteel Heers'" as the summary,
  one child entry per deleted line ("Wannes deleted line 'Cleaning fee' from offer
  'Kasteel Heers' (offer deleted)"), one per removed override ("Wannes removed the
  override on 'Sound' (offer deleted)", `DR-56`), one per removed reference
  (`References.delete_owner_references/2`), one per task detached
  (`WeddingPlanner.Tasks.detach_offer/2`, `DR-8`/`DR-69`) and — for a confirmed offer —
  one "Wannes discarded the confirmed scope of offer 'Venue A' (offer deleted)" for its
  frozen rows (`DR-67`), all before the offer row itself is deleted, since
  `offer_lines.offer_id`, `offer_overrides.offer_id`, `references.offer_id`,
  `tasks.link_offer_id` and `offer_frozen_services.offer_id` are all
  `on_delete: :restrict`. Files are purged (`References.purge_deleted/1`) only after the
  transaction commits; each line's, override's and frozen row's `{:deleted, id}`, each
  detached task's `{:updated, task}` on `:task`, and then the offer's own `{:deleted, id}`
  are broadcast last (`XC-01`).
  """
  @spec delete_offer(Scope.t(), Offer.t()) :: {:ok, Offer.t()} | {:error, :has_invoices}
  def delete_offer(%Scope{} = scope, %Offer{} = offer) do
    if offer_deletion_blockers(offer) == [] do
      {:ok,
       {deleted, deleted_lines, deleted_overrides, deleted_references, detached_tasks,
        deleted_frozen}} =
        Log.action(
          scope,
          "#{actor(scope)} deleted offer '#{offer.vendor_name}'",
          fn ->
            deleted_lines = delete_offer_lines(scope, offer)
            deleted_overrides = delete_offer_overrides(scope, offer)
            deleted_references = References.delete_owner_references(scope, reference_owner(offer))
            detached_tasks = Tasks.detach_offer(scope, offer)
            # C5, DR-67: `offer_frozen_services.offer_id` is `on_delete: :restrict`.
            deleted_frozen = delete_frozen_services(scope, offer, :offer_deleted)
            {:ok, deleted} = Repo.delete(offer)

            {deleted, deleted_lines, deleted_overrides, deleted_references, detached_tasks,
             deleted_frozen}
          end
        )

      :ok = References.purge_deleted(deleted_references)
      Enum.each(deleted_lines, &Realtime.broadcast_change(@line_resource, {:deleted, &1.id}))

      Enum.each(
        deleted_overrides,
        &Realtime.broadcast_change(@override_resource, {:deleted, &1.id})
      )

      Enum.each(detached_tasks, &Realtime.broadcast_change(:task, {:updated, &1}))
      Enum.each(deleted_frozen, &Realtime.broadcast_change(@frozen_resource, {:deleted, &1.id}))
      Realtime.broadcast_change(@resource, {:deleted, deleted.id})
      {:ok, deleted}
    else
      {:error, :has_invoices}
    end
  end

  @doc """
  `DR-58`: the reasons `offer` cannot yet be deleted — any invoice still linked to it
  (`[%{label: "2 invoices", count: 2}]`, singular "1 invoice"). A non-empty result means
  `delete_offer/2` must refuse.
  """
  @spec offer_deletion_blockers(Offer.t()) :: [%{label: String.t(), count: pos_integer()}]
  def offer_deletion_blockers(%Offer{} = offer) do
    case Invoices.count_invoices_by_offer(offer) do
      0 -> []
      n -> [%{label: "#{n} #{pluralize(n, "invoice")}", count: n}]
    end
  end

  @doc """
  What deleting `offer` removes, for the deletion confirmation (`XC-24`, `XC-40`): its
  lines (`%{label: "5 lines", count: 5}`, omitted when it has none), its overrides
  likewise (`DR-56`), its confirmed scope when it has one
  (`%{label: "Its confirmed scope (4 services)", count: 4}`, `DR-67`), its references,
  then a task-link entry (`WeddingPlanner.Tasks.offer_link_reference/1`, `DR-8`/`DR-69`)
  when any task links to this offer.
  """
  @spec offer_deletion_effects(Offer.t()) :: [%{label: String.t(), count: non_neg_integer()}]
  def offer_deletion_effects(%Offer{} = offer) do
    lines =
      case OfferLine |> where([l], l.offer_id == ^offer.id) |> Repo.aggregate(:count) do
        0 -> []
        n -> [%{label: "#{n} #{pluralize(n, "line")}", count: n}]
      end

    overrides =
      case Override |> where([o], o.offer_id == ^offer.id) |> Repo.aggregate(:count) do
        0 -> []
        n -> [%{label: "#{n} #{pluralize(n, "override")}", count: n}]
      end

    frozen =
      case offer |> frozen_services_query() |> Repo.aggregate(:count) do
        0 -> []
        n -> [%{label: "Its confirmed scope (#{n} #{pluralize(n, "service")})", count: n}]
      end

    task_link =
      case Tasks.offer_link_reference(offer) do
        nil -> []
        entry -> [entry]
      end

    lines ++
      overrides ++
      frozen ++ References.reference_deletion_effects(reference_owner(offer)) ++ task_link
  end

  @doc "The `WeddingPlanner.References.Owner` C2 promised B1 (`DR-28`)."
  @spec reference_owner(Offer.t()) :: Owner.t()
  def reference_owner(%Offer{} = offer) do
    %Owner{
      attrs: %{offer_id: offer.id},
      log_entity: {:offer, offer.id},
      name: "offer '#{offer.vendor_name}'"
    }
  end

  @doc "How many offers `category` has — `WeddingPlanner.Categories.category_deletion_blockers/1`'s `DR-26` Q11 check."
  @spec count_offers(Category.t()) :: non_neg_integer()
  def count_offers(%Category{id: category_id}) do
    Offer |> where([o], o.category_id == ^category_id) |> Repo.aggregate(:count)
  end

  @doc """
  `WeddingPlanner.Log.EntityRef` resolver for the `"offer"` entity type: an existing
  offer resolves to `"<vendor name> (<category name>)"` and `/offers/<id>` (task 51). A
  deleted offer is `:error` (degrades to plain text).
  """
  @spec resolve_log_entity(term()) :: {:ok, String.t(), String.t() | nil} | :error
  def resolve_log_entity(id) do
    case Repo.get(Offer, id) do
      nil ->
        :error

      offer ->
        offer = Repo.preload(offer, :category)
        {:ok, "#{offer.vendor_name} (#{offer.category.name})", "/offers/#{offer.id}"}
    end
  end

  # -- Offer lines (DR-41) --------------------------------------------------------------

  @doc """
  `offer`'s lines in display order (`DR-41`): service lines in the category's service
  order (`services.sort_order`, then service id, then line id — `CST-23` allows several
  per service), then ad hoc lines by id. `:service` and `:event` preloaded.
  """
  @spec list_lines(Offer.t()) :: [OfferLine.t()]
  def list_lines(%Offer{id: offer_id}) do
    from(l in OfferLine,
      left_join: s in assoc(l, :service),
      where: l.offer_id == ^offer_id,
      order_by: [asc: is_nil(l.service_id), asc: s.sort_order, asc: s.id, asc: l.id],
      preload: [:event, service: s]
    )
    |> Repo.all()
  end

  @doc "Fetches one line by id, `:service` and `:event` preloaded. Raises if it does not exist."
  @spec get_line!(term()) :: OfferLine.t()
  def get_line!(id), do: OfferLine |> Repo.get!(id) |> Repo.preload(@line_preloads)

  @doc """
  A changeset for building/validating a line form — never persists on its own.
  `line.offer_id` MUST already be set (a persisted line, or `%OfferLine{offer_id: id}`).
  Adds the query-backed checks to `OfferLine.changeset/2`'s structural rules (see the
  moduledoc's "Offer lines" section).
  """
  @spec change_line(OfferLine.t(), map()) :: Ecto.Changeset.t()
  def change_line(%OfferLine{} = line, attrs \\ %{}) do
    offer = line.offer_id && Repo.get(Offer, line.offer_id)

    line
    |> OfferLine.changeset(attrs)
    |> validate_line_offer(offer)
    |> validate_line_service(offer)
    |> validate_line_event()
    |> validate_line_vat_rate(offer)
  end

  @doc """
  Adds a line to `offer` (`CST-20`). Logs "Wannes added line 'Catering (per adult,
  Dinner)' to offer 'Venue A'" against the offer (`XC-10`) and broadcasts
  `{:created, line}` on `:offer_line` (`XC-01`).
  """
  @spec create_line(Scope.t(), Offer.t(), map()) ::
          {:ok, OfferLine.t()} | {:error, Ecto.Changeset.t()}
  def create_line(%Scope{} = scope, %Offer{} = offer, attrs) do
    with {:ok, line} <- %OfferLine{offer_id: offer.id} |> change_line(attrs) |> Repo.insert() do
      line = Repo.preload(line, @line_preloads)

      {:ok, _} =
        Log.entry(
          scope,
          {:offer, line.offer_id},
          "#{actor(scope)} added line '#{line_label(line)}' to offer '#{vendor_name(line.offer_id)}'"
        )

      Realtime.broadcast_change(@line_resource, {:created, line})
      {:ok, line}
    end
  end

  @doc """
  Updates a line. Logs one entry per changed field against the offer (`XC-10`), naming
  the line as it was: "Wannes changed the amount of line 'Catering (per adult, Dinner)' in
  offer 'Venue A': € 85,00 → € 90,00". Fields cleared by normalisation (an unpriced state,
  a flat basis) are logged like any other change. Broadcasts `{:updated, line}` once.
  """
  @spec update_line(Scope.t(), OfferLine.t(), map()) ::
          {:ok, OfferLine.t()} | {:error, Ecto.Changeset.t()}
  def update_line(%Scope{} = scope, %OfferLine{} = line, attrs) do
    before = Repo.preload(line, @line_preloads, force: true)
    changeset = change_line(before, attrs)

    with {:ok, updated} <- Repo.update(changeset) do
      updated = Repo.preload(updated, @line_preloads, force: true)
      :ok = log_line_changes(scope, before, updated, changeset)
      Realtime.broadcast_change(@line_resource, {:updated, updated})
      {:ok, updated}
    end
  end

  @doc """
  Deletes a line. Logs "Wannes deleted line 'Cleaning fee' from offer 'Venue A'" against
  the offer (`XC-10`) and broadcasts `{:deleted, id}` (`XC-01`).
  """
  @spec delete_line(Scope.t(), OfferLine.t()) :: {:ok, OfferLine.t()}
  def delete_line(%Scope{} = scope, %OfferLine{} = line) do
    line = Repo.preload(line, @line_preloads, force: true)
    label = line_label(line)
    {:ok, deleted} = Repo.delete(line)

    {:ok, _} =
      Log.entry(
        scope,
        {:offer, deleted.offer_id},
        "#{actor(scope)} deleted line '#{label}' from offer '#{vendor_name(deleted.offer_id)}'"
      )

    Realtime.broadcast_change(@line_resource, {:deleted, deleted.id})
    {:ok, deleted}
  end

  @doc """
  `CST-22`: turns an optional ad hoc line on or off. `{:error, :not_optional_ad_hoc}` for
  any other line. Logs "Wannes turned on 'Corkage fee' in offer 'Venue A'" (or "turned
  off") and broadcasts `{:updated, line}`; setting the value it already has is a no-op.

  On a **confirmed** offer the toggle is the line's frozen state (`CST-43` case 3,
  `DR-61`, `DR-64`), so the same write extends or shrinks what counts toward the
  committed total and the entry says so: "… turned on 'Corkage fee' in offer 'Venue A'
  (added to the confirmed scope)" / "… turned off … (removed from the confirmed scope)".
  """
  @spec set_line_enabled(Scope.t(), OfferLine.t(), boolean()) ::
          {:ok, OfferLine.t()} | {:error, :not_optional_ad_hoc}
  def set_line_enabled(%Scope{} = scope, %OfferLine{} = line, enabled) when is_boolean(enabled) do
    cond do
      not OfferLine.optional_ad_hoc?(line) ->
        {:error, :not_optional_ad_hoc}

      line.enabled == enabled ->
        {:ok, Repo.preload(line, @line_preloads)}

      true ->
        {:ok, updated} = line |> OfferLine.enabled_changeset(enabled) |> Repo.update()
        updated = Repo.preload(updated, @line_preloads, force: true)
        verb = if enabled, do: "turned on", else: "turned off"
        offer = Repo.get!(Offer, updated.offer_id)

        {:ok, _} =
          Log.entry(
            scope,
            {:offer, updated.offer_id},
            "#{actor(scope)} #{verb} '#{line_label(updated)}' in offer '#{offer.vendor_name}'" <>
              scope_suffix(offer, enabled)
          )

        Realtime.broadcast_change(@line_resource, {:updated, updated})
        {:ok, updated}
    end
  end

  @doc """
  `CST-11` quick offer: an offer in `category` (`vendor_name`, optional `vat_basis` —
  default inclusive — and, for an exclusive offer, `vat_rate_input`) with exactly one
  mandatory flat ad hoc line labelled "Price" whose amount is `amount_input`
  (`WeddingPlanner.Money.parse/2`, in the offer's basis). One `Log.action/3`: "Wannes
  added offer 'Bridal Boutique' to Attire (one flat price € 1.800,00)", with the offer's
  and the line's own entries as children. Broadcasts `{:created, offer}` and
  `{:created, line}` after commit.

  On invalid input nothing is written and the error is the **offer** changeset, carrying
  the line's `amount_input` error too, so one short form can show both.
  """
  @spec create_simple_offer(Scope.t(), Category.t(), map()) ::
          {:ok, Offer.t()} | {:error, Ecto.Changeset.t()}
  def create_simple_offer(%Scope{} = scope, %Category{} = category, attrs) do
    attrs = Map.new(attrs, fn {key, value} -> {to_string(key), value} end)

    offer_changeset =
      change_offer(
        %Offer{category_id: category.id},
        Map.take(attrs, ["vendor_name", "vat_basis", "vat_rate_input", "amount_input"])
      )

    line_changeset =
      OfferLine.changeset(%OfferLine{}, %{
        "label" => "Price",
        "state" => "mandatory",
        "basis" => "flat",
        "amount_input" => Map.get(attrs, "amount_input") || ""
      })

    if offer_changeset.valid? and line_changeset.valid? do
      insert_simple_offer(scope, category, offer_changeset, line_changeset)
    else
      changeset =
        Enum.reduce(line_changeset.errors, offer_changeset, fn {field, {message, opts}}, acc ->
          Ecto.Changeset.add_error(acc, field, message, opts)
        end)

      {:error, %{changeset | action: :insert}}
    end
  end

  @doc """
  A line's name for logs and screens (`DR-41`): an ad hoc line is its label ("Cleaning
  fee"); a service line is the service name plus what tells its lines apart — basis and
  event for a per-person line ("Catering (per adult, Dinner)"; "Catering (per adult)"
  once its event is gone), the state otherwise ("Sound (included)", "Garden ceremony
  (optional)"). Uses the preloaded `:service`/`:event`, loading them if absent.
  """
  @spec line_label(OfferLine.t()) :: String.t()
  def line_label(%OfferLine{service_id: nil, label: label}), do: label

  def line_label(%OfferLine{} = line) do
    line = Repo.preload(line, @line_preloads)

    name =
      if line.variation, do: "#{line.service.name}: #{line.variation}", else: line.service.name

    "#{name} (#{line_descriptor(line)})"
  end

  @doc "`CST-06`: how many offer lines reference `service` (any offer, any state)."
  @spec count_service_lines(Service.t()) :: non_neg_integer()
  def count_service_lines(%Service{id: service_id}) do
    OfferLine |> where([l], l.service_id == ^service_id) |> Repo.aggregate(:count)
  end

  @doc """
  `CST-04`: points every line of `absorbed` at `survivor`, with one child entry per
  affected offer ("Wannes moved 2 lines of offer 'Venue A' from 'Sound system' to 'Sound'
  (services merged)"). Returns the moved lines (preloaded) for the caller's post-commit
  `{:updated, line}` broadcasts.

  **Must be called inside `WeddingPlanner.Categories.merge_services/3`'s
  `Log.action/3`**, before the absorbed service is deleted: it starts no transaction and
  broadcasts nothing.
  """
  @spec move_service_lines(Scope.t(), Service.t(), Service.t()) :: [OfferLine.t()]
  def move_service_lines(%Scope{} = scope, %Service{} = absorbed, %Service{} = survivor) do
    query = where(OfferLine, [l], l.service_id == ^absorbed.id)

    case Repo.all(order_by(query, [l], asc: l.id)) do
      [] ->
        []

      lines ->
        now = DateTime.utc_now(:second)
        {_count, _} = Repo.update_all(query, set: [service_id: survivor.id, updated_at: now])

        lines
        |> Enum.group_by(& &1.offer_id)
        |> Enum.sort_by(fn {offer_id, _lines} -> offer_id end)
        |> Enum.each(fn {offer_id, offer_lines} ->
          n = length(offer_lines)

          {:ok, _} =
            Log.entry(
              scope,
              {:offer, offer_id},
              "#{actor(scope)} moved #{n} #{pluralize(n, "line")} of offer '#{vendor_name(offer_id)}' " <>
                "from '#{absorbed.name}' to '#{survivor.name}' (services merged)"
            )
        end)

        ids = Enum.map(lines, & &1.id)

        from(l in OfferLine, where: l.id in ^ids, order_by: [asc: l.id], preload: ^@line_preloads)
        |> Repo.all()
    end
  end

  @doc """
  `XC-41`, `DR-42`: clears `event` from every line referencing it, so each becomes
  invalid (`OfferLine.invalid?/1`) — never deleted, never repaired automatically
  (`XC-42`). One child entry per line, against its offer: "Wannes deleted event 'Dinner':
  line 'Catering (per adult)' in offer 'Venue A' is now invalid". Returns the updated
  lines (preloaded) for the caller's post-commit `{:updated, line}` broadcasts.

  **Must be called inside `WeddingPlanner.Events.delete_event/2`'s `Log.action/3`**,
  before the event row is deleted (`offer_lines.event_id` is `on_delete: :restrict`): it
  starts no transaction and broadcasts nothing.
  """
  @spec detach_event(Scope.t(), Event.t()) :: [OfferLine.t()]
  def detach_event(%Scope{} = scope, %Event{} = event) do
    OfferLine
    |> where([l], l.event_id == ^event.id)
    |> order_by([l], asc: l.id)
    |> Repo.all()
    |> Enum.map(fn line ->
      # Deliberately not `OfferLine.changeset/2`: that would refuse a per-person line
      # without an event, which is exactly the (derived) invalid state XC-41 asks for.
      {:ok, updated} = line |> Ecto.Changeset.change(event_id: nil) |> Repo.update()
      updated = Repo.preload(updated, @line_preloads, force: true)

      {:ok, _} =
        Log.entry(
          scope,
          {:offer, updated.offer_id},
          "#{actor(scope)} deleted event '#{event.name}': line '#{line_label(updated)}' " <>
            "in offer '#{vendor_name(updated.offer_id)}' is now invalid"
        )

      updated
    end)
  end

  @doc """
  `EVT-05` provider (`DR-42`): how many offer lines reference `event` —
  `%{label: "3 offer lines (they become invalid)", count: 3}` — or `nil` when none do.
  Registered via `config :wedding_planner, event_reference_providers:`.
  """
  @spec event_offer_line_reference(Event.t()) :: %{label: String.t(), count: pos_integer()} | nil
  def event_offer_line_reference(%Event{id: event_id}) do
    case OfferLine |> where([l], l.event_id == ^event_id) |> Repo.aggregate(:count) do
      0 -> nil
      1 -> %{label: "1 offer line (it becomes invalid)", count: 1}
      n -> %{label: "#{n} offer lines (they become invalid)", count: n}
    end
  end

  # -- Overrides (CST-24, CST-52, DR-49, DR-56) ------------------------------------------

  @doc "`offer`'s override rows, `id` order (`DR-49`)."
  @spec list_overrides(Offer.t()) :: [Override.t()]
  def list_overrides(%Offer{id: offer_id}) do
    Override
    |> where([o], o.offer_id == ^offer_id)
    |> order_by([o], asc: o.id)
    |> Repo.all()
  end

  @doc """
  `CST-24`, `CST-52`: toggles `service` for `offer` — sets it to the opposite of its
  current *effective* wanted (`Valuation.Selection.effectively_wanted?/3`, the single
  `CST-24` definition, run here over a snapshot holding only the current stored row for
  this one offer × service). Refuses `{:error, :wrong_category}` when `service` is not
  one of `offer`'s own category's services.

  When the flipped value equals what the category priority alone would give (the
  default), the row is **deleted** instead of written — a toggle never leaves a row that
  agrees with the default. Otherwise the row is upserted with the flipped value
  (`on_conflict: {:replace, [:wanted, :updated_at]}`, conflict target the offer ×
  service pair) — this is also how a row that has come to coincide with the default
  because the priority changed later diverges again, or moves to the new deviation.

  Logs one entry against the **offer** (`XC-10`): "Wannes turned off 'Sound' for offer
  'Venue A' (override)" / "…turned on…" when a row is written, "Wannes removed the
  override on 'Sound' for offer 'Venue A'" when the toggle deletes it instead.
  Broadcasts `{:created | :updated, override}` / `{:deleted, id}` on `:override`
  (`XC-01`) after commit. Returns the resulting effective `wanted` either way, so a
  caller never has to re-derive it.

  Refuses `{:error, :confirmed}` — before anything else, nothing written — when the
  offer is **confirmed** (read from the database, not from the given struct): while
  confirmed, `Valuation.Selection` ignores override rows (the frozen selection decides,
  `CST-40`, `DR-64`), and the one-row snapshot built here would read an empty frozen set.
  Rows written before the confirmation are kept and resume after un-confirming.
  """
  @spec toggle_override(Scope.t(), Offer.t(), Service.t()) ::
          {:ok, %{wanted: boolean(), override: Override.t() | nil}}
          | {:error, :wrong_category | :confirmed}
  def toggle_override(%Scope{} = scope, %Offer{} = offer, %Service{} = service) do
    # DR-64: checked first, against the stored status.
    status = current_status!(offer)

    cond do
      status == :confirmed ->
        {:error, :confirmed}

      service.category_id != offer.category_id ->
        {:error, :wrong_category}

      true ->
        offer = %{offer | status: status}
        existing = get_override(offer.id, service.id)
        snapshot = %Snapshot{overrides: List.wrap(existing)}
        effective = Selection.effectively_wanted?(snapshot, offer, service)
        default = service.wanted_priority in [:nice_to_have, :must_have]
        target = not effective

        if target == default do
          drop_override(scope, offer, service, existing, target)
        else
          write_override(scope, offer, service, existing, target)
        end
    end
  end

  @doc """
  `CST-27`: makes `variation` the active variation of `service` in `offer`. Marks that variation's lines
  `chosen` (and unmarks the service's others), logs "Wannes chose 'Champagne' for 'Drinks' in offer
  'Venue A'" against the offer and broadcasts `{:updated, line}` on `:offer_line` per changed line. Allowed on
  a confirmed offer. Choosing the already active variation is a no-op.

  `{:error, :unknown_variation}` when no line of `offer` for `service` carries that name;
  `{:error, :wrong_category}` when the service is not of the offer's category.
  """
  @spec choose_variation(Scope.t(), Offer.t(), Service.t(), String.t()) ::
          {:ok, Offer.t()} | {:error, :unknown_variation | :wrong_category}
  def choose_variation(%Scope{} = scope, %Offer{} = offer, %Service{} = service, variation)
      when is_binary(variation) do
    offer = Repo.get!(Offer, offer.id)
    snapshot = %Snapshot{offer_lines: Repo.all(where(OfferLine, [l], l.offer_id == ^offer.id))}

    cond do
      service.category_id != offer.category_id ->
        {:error, :wrong_category}

      variation not in Selection.variations(snapshot, offer, service.id) ->
        {:error, :unknown_variation}

      Selection.active_variation(snapshot, offer, service.id) == variation ->
        {:ok, offer}

      true ->
        # One transaction: unmark the service's lines, mark the chosen variation's.
        {:ok, updated_lines} =
          Repo.transaction(fn ->
            lines =
              Repo.all(
                where(OfferLine, [l], l.offer_id == ^offer.id and l.service_id == ^service.id)
              )

            for line <- lines,
                chosen = line.variation == variation,
                line.chosen != chosen do
              line |> Ecto.Changeset.change(chosen: chosen) |> Repo.update!()
            end
          end)

        {:ok, _} =
          Log.entry(
            scope,
            {:offer, offer.id},
            "#{actor(scope)} chose '#{variation}' for '#{service.name}' in offer '#{offer.vendor_name}'"
          )

        for line <- updated_lines do
          Realtime.broadcast_change(
            @line_resource,
            {:updated, Repo.preload(line, @line_preloads)}
          )
        end

        {:ok, offer}
    end
  end

  @doc """
  Deletes every override that targets `service` (any offer), one child entry per
  affected offer: "Wannes removed the override on 'Sound system' for offer 'Venue A'
  (service deleted)" (`DR-56`). **Must be called inside
  `WeddingPlanner.Categories.delete_service/2`'s `Log.action/3`**, before the service row
  is deleted: it starts no transaction and broadcasts nothing. Returns the deleted
  overrides for the caller's post-commit `{:deleted, id}` broadcasts.
  """
  @spec delete_service_overrides(Scope.t(), Service.t()) :: [Override.t()]
  def delete_service_overrides(%Scope{} = scope, %Service{} = service) do
    service
    |> service_overrides_query()
    |> Repo.all()
    |> Enum.map(fn override ->
      offer = Repo.get!(Offer, override.offer_id)
      {:ok, deleted} = Repo.delete(override)

      {:ok, _} =
        Log.entry(
          scope,
          {:offer, offer.id},
          "#{actor(scope)} removed the override on '#{service.name}' for offer " <>
            "'#{offer.vendor_name}' (service deleted)"
        )

      deleted
    end)
  end

  @doc "How many overrides target `service` — `Categories.delete_service/2`'s `DR-56` check."
  @spec count_service_overrides(Service.t()) :: non_neg_integer()
  def count_service_overrides(%Service{} = service) do
    service |> service_overrides_query() |> Repo.aggregate(:count)
  end

  @doc """
  `CST-04`, `DR-56`: moves every override targeting `absorbed` to `survivor`, except
  where `survivor` already has an override for that offer — then the absorbed row is
  dropped instead (the survivor's row wins). One child entry per affected offer:
  "Wannes moved the override on 'Sound system' to 'Sound' for offer 'Venue A' (merge)",
  or "Wannes dropped the override on 'Sound system' for offer 'Venue A' (the offer
  already overrides 'Sound')". Returns `{moved, dropped}`, each a list of the resulting
  `Override.t()`, for the caller's post-commit broadcasts (`{:updated, override}` /
  `{:deleted, id}`).

  **Must be called inside `WeddingPlanner.Categories.merge_services/3`'s
  `Log.action/3`**, before the absorbed service is deleted: it starts no transaction and
  broadcasts nothing.
  """
  @spec move_service_overrides(Scope.t(), Service.t(), Service.t()) ::
          {moved :: [Override.t()], dropped :: [Override.t()]}
  def move_service_overrides(%Scope{} = scope, %Service{} = absorbed, %Service{} = survivor) do
    absorbed_overrides = absorbed |> service_overrides_query() |> Repo.all()

    survivor_offer_ids =
      survivor
      |> service_overrides_query()
      |> select([o], o.offer_id)
      |> Repo.all()
      |> MapSet.new()

    {moved, dropped} =
      Enum.reduce(absorbed_overrides, {[], []}, fn override, {moved, dropped} ->
        offer = Repo.get!(Offer, override.offer_id)

        if MapSet.member?(survivor_offer_ids, override.offer_id) do
          {:ok, deleted} = Repo.delete(override)

          {:ok, _} =
            Log.entry(
              scope,
              {:offer, offer.id},
              "#{actor(scope)} dropped the override on '#{absorbed.name}' for offer " <>
                "'#{offer.vendor_name}' (the offer already overrides '#{survivor.name}')"
            )

          {moved, [deleted | dropped]}
        else
          {:ok, updated} =
            override |> Ecto.Changeset.change(service_id: survivor.id) |> Repo.update()

          {:ok, _} =
            Log.entry(
              scope,
              {:offer, offer.id},
              "#{actor(scope)} moved the override on '#{absorbed.name}' to " <>
                "'#{survivor.name}' for offer '#{offer.vendor_name}' (merge)"
            )

          {[updated | moved], dropped}
        end
      end)

    {Enum.reverse(moved), Enum.reverse(dropped)}
  end

  # -- Confirmation, frozen selection, planning pick (C5) ---------------------------------

  @doc "`offer`'s frozen selection rows (`CST-40`, `DR-61`), `id` order — none unless it is confirmed."
  @spec list_frozen_services(Offer.t()) :: [FrozenService.t()]
  def list_frozen_services(%Offer{} = offer) do
    offer |> frozen_services_query() |> order_by([f], asc: f.id) |> Repo.all()
  end

  @doc """
  `CST-40`, `DR-62`: confirms `offer` from any other status, immediately, freezing its
  effective selection. One `Log.action/3` — "Wannes confirmed offer 'Venue A'" — whose
  transaction:

    1. re-reads the offer's status and refuses `{:error, :already_confirmed}` (nothing
       written, nothing logged) when it is already confirmed — also when a concurrent
       confirm won the race (`DR-62`; `Log.action/3`'s leading summary insert takes
       SQLite's write lock, so the second caller only reads after the first committed);
    2. computes the frozen set with `Valuation.Selection.freeze/2` — the single definition
       of what a confirmation captures (priorities + overrides, `CST-24`), never re-derived
       here — over a `%Snapshot{}` of the category's services, this offer, its lines and
       its override rows;
    3. writes `status: :confirmed, planning_pick: false` in one `UPDATE`
       (`Offer.confirmation_changeset/2`) and one `WeddingPlanner.Offers.FrozenService` row
       per frozen service;
    4. clears **another** offer's planning pick in the category (`DR-66`: a pick only
       lives "until something is confirmed").

  Child entries: "Wannes changed the status of offer 'Venue A': shortlisted → confirmed";
  "Wannes froze 4 services for offer 'Venue A': Seating, Catering, Sound, Late-night
  snack" ("froze no services for offer 'Venue A'" when empty); when the offer itself was
  the pick, "Wannes cleared offer 'Venue A' as the planning pick for Venue (offer
  confirmed)"; and on another offer that was the pick, "Wannes cleared offer 'Venue B' as
  the planning pick for Venue (an offer in Venue was confirmed)". Several confirmed offers
  per category are allowed (`D-20`). After commit: `{:created, row}` on `:frozen_service`
  per row, then `{:updated, offer}` on `:offer` for every changed offer, the confirmed one
  last. Returns the confirmed offer, `:category` preloaded.
  """
  @spec confirm_offer(Scope.t(), Offer.t()) :: {:ok, Offer.t()} | {:error, :already_confirmed}
  def confirm_offer(%Scope{} = scope, %Offer{} = offer) do
    result =
      Log.action(scope, "#{actor(scope)} confirmed offer '#{offer.vendor_name}'", fn ->
        confirm_and_log(scope, offer.id)
      end)

    case result do
      {:ok, {confirmed, frozen, cleared_picks}} ->
        Enum.each(frozen, &Realtime.broadcast_change(@frozen_resource, {:created, &1}))
        Enum.each(cleared_picks, &Realtime.broadcast_change(@resource, {:updated, &1}))
        Realtime.broadcast_change(@resource, {:updated, confirmed})
        {:ok, confirmed}

      {:error, :already_confirmed} = error ->
        error
    end
  end

  @doc """
  `CST-42`, `DR-62`, `DR-65`: un-confirms `offer` — its frozen selection is discarded and
  it returns to *shortlisted*, whatever its status was before confirmation. The caller
  asks first (`XC-40`, naming `unconfirm_effects/1`).

  Refuses, with nothing written and nothing logged:

    * `{:error, :not_confirmed}` when the offer (re-read inside the transaction) is not
      confirmed;
    * `{:error, :has_invoices}` while any invoice links to it (`DR-65`, user-decided:
      "refuse for now") — `unconfirm_blockers/1` is the refusal's copy.

  Otherwise one `Log.action/3` — "Wannes un-confirmed offer 'Venue A'" — that writes
  `status: :shortlisted, invoicing_complete: false` in **one** `UPDATE` (the `DR-58`
  CHECK) and deletes the frozen rows. Child entries: "Wannes changed the status of offer
  'Venue A': confirmed → shortlisted"; "Wannes discarded the confirmed scope of offer
  'Venue A' (4 services)"; and, only when it was set, "Wannes cleared invoicing complete
  for offer 'Venue A' (offer un-confirmed)". The offer's override rows were never touched
  while it was confirmed, so they are in force again (`DR-64`); a planning pick cleared by
  the confirmation is not restored (`DR-66`). After commit: `{:deleted, id}` on
  `:frozen_service` per row, then `{:updated, offer}` on `:offer`. Returns the offer,
  `:category` preloaded.
  """
  @spec unconfirm_offer(Scope.t(), Offer.t()) ::
          {:ok, Offer.t()} | {:error, :not_confirmed | :has_invoices}
  def unconfirm_offer(%Scope{} = scope, %Offer{} = offer) do
    result =
      Log.action(scope, "#{actor(scope)} un-confirmed offer '#{offer.vendor_name}'", fn ->
        unconfirm_and_log(scope, offer.id)
      end)

    case result do
      {:ok, {updated, discarded}} ->
        Enum.each(discarded, &Realtime.broadcast_change(@frozen_resource, {:deleted, &1.id}))
        Realtime.broadcast_change(@resource, {:updated, updated})
        {:ok, updated}

      {:error, reason} when reason in [:not_confirmed, :has_invoices] ->
        {:error, reason}
    end
  end

  @doc """
  `DR-65`: why `offer` cannot be un-confirmed yet — `[]`, or one sentence naming the
  linked invoices: `["2 invoices are linked to it: 'Venue deposit', 'Final invoice' —
  unlink them first"]` (singular: "1 invoice is linked to it: 'Venue deposit' — unlink it
  first"). A non-empty result means `unconfirm_offer/2` refuses with
  `{:error, :has_invoices}`.
  """
  @spec unconfirm_blockers(Offer.t()) :: [String.t()]
  def unconfirm_blockers(%Offer{} = offer) do
    case Invoices.list_invoices_by_offer(offer) do
      [] ->
        []

      [invoice] ->
        ["1 invoice is linked to it: '#{invoice.label}' — unlink it first"]

      invoices ->
        labels = Enum.map_join(invoices, ", ", &"'#{&1.label}'")
        ["#{length(invoices)} invoices are linked to it: #{labels} — unlink them first"]
    end
  end

  @doc """
  What un-confirming `offer` changes, for the `XC-40` confirmation (`CST-42`): its frozen
  services (`%{label: "4 services leave the confirmed scope", count: 4}`, singular "1
  service leaves the confirmed scope"; omitted when there are none) and, only when set,
  `%{label: "Invoicing complete will be cleared", count: 1}`.
  """
  @spec unconfirm_effects(Offer.t()) :: [%{label: String.t(), count: non_neg_integer()}]
  def unconfirm_effects(%Offer{} = offer) do
    services =
      case offer |> frozen_services_query() |> Repo.aggregate(:count) do
        0 -> []
        1 -> [%{label: "1 service leaves the confirmed scope", count: 1}]
        n -> [%{label: "#{n} services leave the confirmed scope", count: n}]
      end

    invoicing_complete? =
      Repo.exists?(from(o in Offer, where: o.id == ^offer.id and o.invoicing_complete == true))

    invoicing =
      if invoicing_complete?,
        do: [%{label: "Invoicing complete will be cleared", count: 1}],
        else: []

    services ++ invoicing
  end

  @doc """
  `CST-43` case 2, `DR-64`: adds `service` to confirmed `offer`'s frozen selection — the
  "add to confirmed scope" action on a greyed-out line. Allowed for any service of the
  offer's own category. Refuses, writing nothing: `{:error, :not_confirmed}` (the stored
  status is checked), `{:error, :wrong_category}`, `{:error, :already_in_scope}` (also
  when a concurrent add won). Scope only grows — there is no "remove from scope".
  Logs "Wannes added 'Sound' to the confirmed scope of offer 'Venue A'" against the offer
  and broadcasts `{:created, row}` on `:frozen_service`.
  """
  @spec add_to_confirmed_scope(Scope.t(), Offer.t(), Service.t()) ::
          {:ok, FrozenService.t()}
          | {:error, :not_confirmed | :wrong_category | :already_in_scope}
  def add_to_confirmed_scope(%Scope{} = scope, %Offer{} = offer, %Service{} = service) do
    # `mode: :immediate`: the status re-read and the insert are one read-then-write, so the
    # write lock is taken before the read (the `WeddingPlanner.Accounts.Passkeys` pattern)
    # — an add racing an un-confirm can never leave a row on a non-confirmed offer.
    result =
      Repo.transaction(fn -> insert_frozen_service(offer.id, service) end, mode: :immediate)

    case result do
      {:ok, {current, row}} ->
        {:ok, _} =
          Log.entry(
            scope,
            {:offer, current.id},
            "#{actor(scope)} added '#{service.name}' to the confirmed scope of offer " <>
              "'#{current.vendor_name}'"
          )

        Realtime.broadcast_change(@frozen_resource, {:created, row})
        {:ok, row}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc """
  `CST-44`, `DR-66`: makes `offer` its category's planning pick. Refuses, writing nothing:
  `{:error, :confirmed}` / `{:error, :rejected}` for such an offer, and
  `{:error, :category_has_confirmed_offer}` once the category has a confirmed offer (all
  re-read inside the transaction). Setting the current pick again is a no-op
  (`{:ok, offer}`, nothing logged).

  Otherwise **moves** the pick in one `Log.action/3` — "Wannes made offer 'Venue B' the
  planning pick for Venue" — clearing the old pick first (the partial unique index
  `offers_one_planning_pick_per_category` allows one per category), with an entry on each
  offer: "Wannes cleared offer 'Venue A' as the planning pick for Venue (moved to offer
  'Venue B')" and "Wannes made offer 'Venue B' the planning pick for Venue". Broadcasts
  `{:updated, offer}` on `:offer` for each changed offer, the new pick last.

  Concurrency: two callers picking different offers of one category are serialised by
  `Log.action/3`'s leading summary insert (SQLite's single write lock, taken before
  anything is read), and each re-reads the current pick after acquiring it — so the second
  one moves the pick from the first one's offer to its own. Both return `{:ok, _}`, the
  last writer's offer is the pick, and the unique index never fires (it stays the
  backstop).
  """
  @spec set_planning_pick(Scope.t(), Offer.t()) ::
          {:ok, Offer.t()} | {:error, :category_has_confirmed_offer | :rejected | :confirmed}
  def set_planning_pick(%Scope{} = scope, %Offer{} = offer) do
    category_name = Repo.get!(Category, offer.category_id).name

    result =
      Log.action(
        scope,
        "#{actor(scope)} made offer '#{offer.vendor_name}' the planning pick for #{category_name}",
        fn -> move_pick_and_log(scope, offer.id, category_name) end
      )

    case result do
      {:ok, {cleared, picked}} ->
        Enum.each(cleared, &Realtime.broadcast_change(@resource, {:updated, &1}))
        Realtime.broadcast_change(@resource, {:updated, picked})
        {:ok, picked}

      {:error, :already_pick} ->
        {:ok, get_offer!(offer.id)}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc """
  `CST-44`, `DR-66`: clears `offer`'s planning pick. Logs "Wannes cleared offer 'Venue B'
  as the planning pick for Venue" and broadcasts `{:updated, offer}`; a no-op (nothing
  logged) when it is not the pick. Returns the offer, `:category` preloaded.
  """
  @spec clear_planning_pick(Scope.t(), Offer.t()) :: {:ok, Offer.t()}
  def clear_planning_pick(%Scope{} = scope, %Offer{} = offer) do
    {count, _} =
      Repo.update_all(
        from(o in Offer, where: o.id == ^offer.id and o.planning_pick == true),
        set: [planning_pick: false, updated_at: DateTime.utc_now(:second)]
      )

    updated = get_offer!(offer.id)

    if count == 1 do
      {:ok, _} =
        Log.entry(scope, {:offer, updated.id}, pick_cleared_description(scope, updated, ""))

      Realtime.broadcast_change(@resource, {:updated, updated})
    end

    {:ok, updated}
  end

  @doc """
  Whether the category (a `%Category{}` or its id) has at least one confirmed offer —
  `CST-44`'s "in a category without a confirmed offer" (`DR-66`).
  """
  @spec category_has_confirmed_offer?(Category.t() | term()) :: boolean()
  def category_has_confirmed_offer?(%Category{id: category_id}),
    do: category_has_confirmed_offer?(category_id)

  def category_has_confirmed_offer?(category_id) do
    Repo.exists?(
      from(o in Offer, where: o.category_id == ^category_id and o.status == :confirmed)
    )
  end

  @doc """
  `CST-06`, `DR-67`: the offers whose frozen selection contains `service`, `id` order —
  `WeddingPlanner.Categories.service_frozen_offers/1` (the service-delete refusal).
  """
  @spec list_offers_freezing_service(Service.t()) :: [Offer.t()]
  def list_offers_freezing_service(%Service{id: service_id}) do
    from(o in Offer,
      join: f in FrozenService,
      on: f.offer_id == o.id,
      where: f.service_id == ^service_id,
      order_by: [asc: o.id],
      distinct: true
    )
    |> Repo.all()
  end

  @doc """
  `CST-04`, `DR-67`: the confirmed offers that have exactly **one** of `absorbed` and
  `survivor` in their frozen selection, `id` order — merging the two would pull the other
  service's optional lines into or out of that offer's committed total, so
  `WeddingPlanner.Categories.merge_services/3` refuses while this is non-empty.
  """
  @spec confirmed_scope_mismatch(Service.t(), Service.t()) :: [Offer.t()]
  def confirmed_scope_mismatch(%Service{} = absorbed, %Service{} = survivor) do
    ids = [absorbed.id, survivor.id]

    mismatched_offer_ids =
      from(f in FrozenService,
        join: o in Offer,
        on: o.id == f.offer_id,
        where: f.service_id in ^ids and o.status == :confirmed,
        group_by: f.offer_id,
        having: count(f.service_id, :distinct) == 1,
        select: f.offer_id
      )
      |> Repo.all()

    from(o in Offer, where: o.id in ^mismatched_offer_ids, order_by: [asc: o.id])
    |> Repo.all()
  end

  @doc """
  `CST-04`, `DR-67`: moves every frozen row of `absorbed` to `survivor` — the absorbed row
  is deleted and, unless the offer already has `survivor` frozen-in, a survivor row is
  inserted. One child entry per affected offer: "Wannes dropped 'Sound system' from the
  confirmed scope of offer 'Venue A' ('Sound' is already in it; services merged)" or
  "Wannes moved the confirmed scope of offer 'Venue A' from 'Sound system' to 'Sound'
  (services merged)". Returns `{created, deleted}` rows for the caller's post-commit
  `{:created, row}` / `{:deleted, id}` broadcasts on `:frozen_service`.

  **Must be called inside `WeddingPlanner.Categories.merge_services/3`'s
  `Log.action/3`**, before the absorbed service is deleted
  (`offer_frozen_services.service_id` is `on_delete: :restrict`): it starts no transaction
  and broadcasts nothing.
  """
  @spec move_service_frozen_rows(Scope.t(), Service.t(), Service.t()) ::
          {created :: [FrozenService.t()], deleted :: [FrozenService.t()]}
  def move_service_frozen_rows(%Scope{} = scope, %Service{} = absorbed, %Service{} = survivor) do
    rows =
      FrozenService
      |> where([f], f.service_id == ^absorbed.id)
      |> order_by([f], asc: f.id)
      |> Repo.all()

    survivor_offer_ids =
      FrozenService
      |> where([f], f.service_id == ^survivor.id)
      |> select([f], f.offer_id)
      |> Repo.all()
      |> MapSet.new()

    {created, deleted} =
      Enum.reduce(rows, {[], []}, fn row, {created, deleted} ->
        offer = Repo.get!(Offer, row.offer_id)
        {:ok, gone} = Repo.delete(row)

        if MapSet.member?(survivor_offer_ids, row.offer_id) do
          {:ok, _} =
            Log.entry(
              scope,
              {:offer, offer.id},
              "#{actor(scope)} dropped '#{absorbed.name}' from the confirmed scope of offer " <>
                "'#{offer.vendor_name}' ('#{survivor.name}' is already in it; services merged)"
            )

          {created, [gone | deleted]}
        else
          {:ok, moved} =
            %FrozenService{offer_id: offer.id, service_id: survivor.id}
            |> FrozenService.changeset()
            |> Repo.insert()

          {:ok, _} =
            Log.entry(
              scope,
              {:offer, offer.id},
              "#{actor(scope)} moved the confirmed scope of offer '#{offer.vendor_name}' " <>
                "from '#{absorbed.name}' to '#{survivor.name}' (services merged)"
            )

          {[moved | created], [gone | deleted]}
        end
      end)

    {Enum.reverse(created), Enum.reverse(deleted)}
  end

  # -- private -------------------------------------------------------------------------

  defp delete_offer_lines(scope, %Offer{} = offer) do
    offer
    |> list_lines()
    |> Enum.map(fn line ->
      {:ok, deleted} = Repo.delete(line)

      {:ok, _} =
        Log.entry(
          scope,
          {:offer, offer.id},
          "#{actor(scope)} deleted line '#{line_label(line)}' from offer '#{offer.vendor_name}' (offer deleted)"
        )

      deleted
    end)
  end

  defp delete_offer_overrides(scope, %Offer{} = offer) do
    offer
    |> list_overrides()
    |> Enum.map(fn override ->
      service = Repo.get!(Service, override.service_id)
      {:ok, deleted} = Repo.delete(override)

      {:ok, _} =
        Log.entry(
          scope,
          {:offer, offer.id},
          "#{actor(scope)} removed the override on '#{service.name}' (offer deleted)"
        )

      deleted
    end)
  end

  defp service_overrides_query(%Service{id: service_id}) do
    where(Override, [o], o.service_id == ^service_id)
  end

  defp get_override(offer_id, service_id) do
    Repo.get_by(Override, offer_id: offer_id, service_id: service_id)
  end

  defp drop_override(_scope, _offer, _service, nil, target),
    do: {:ok, %{wanted: target, override: nil}}

  defp drop_override(scope, offer, service, %Override{} = override, target) do
    {:ok, deleted} = Repo.delete(override)

    {:ok, _} =
      Log.entry(
        scope,
        {:offer, offer.id},
        "#{actor(scope)} removed the override on '#{service.name}' for offer '#{offer.vendor_name}'"
      )

    Realtime.broadcast_change(@override_resource, {:deleted, deleted.id})
    {:ok, %{wanted: target, override: nil}}
  end

  defp write_override(scope, offer, service, existing, target) do
    {:ok, override} =
      %Override{offer_id: offer.id, service_id: service.id}
      |> Override.changeset(%{wanted: target})
      |> Repo.insert(
        on_conflict: {:replace, [:wanted, :updated_at]},
        conflict_target: [:offer_id, :service_id],
        returning: true
      )

    verb = if target, do: "turned on", else: "turned off"

    {:ok, _} =
      Log.entry(
        scope,
        {:offer, offer.id},
        "#{actor(scope)} #{verb} '#{service.name}' for offer '#{offer.vendor_name}' (override)"
      )

    event = if existing, do: :updated, else: :created
    Realtime.broadcast_change(@override_resource, {event, override})
    {:ok, %{wanted: target, override: override}}
  end

  defp insert_simple_offer(scope, category, offer_changeset, line_changeset) do
    vendor = Ecto.Changeset.get_field(offer_changeset, :vendor_name)
    price = Format.money(Ecto.Changeset.get_field(line_changeset, :amount))

    {:ok, {offer, line}} =
      Log.action(
        scope,
        "#{actor(scope)} added offer '#{vendor}' to #{category.name} (one flat price #{price})",
        fn ->
          {:ok, offer} = Repo.insert(offer_changeset)

          {:ok, _} =
            Log.entry(
              scope,
              {:offer, offer.id},
              "#{actor(scope)} added offer '#{offer.vendor_name}' to #{category.name}"
            )

          {:ok, line} =
            line_changeset
            |> Ecto.Changeset.put_change(:offer_id, offer.id)
            |> Repo.insert()

          line = Repo.preload(line, @line_preloads)

          {:ok, _} =
            Log.entry(
              scope,
              {:offer, offer.id},
              "#{actor(scope)} added line '#{line_label(line)}' to offer '#{offer.vendor_name}'"
            )

          {offer, line}
        end
      )

    Realtime.broadcast_change(@resource, {:created, offer})
    Realtime.broadcast_change(@line_resource, {:created, line})
    {:ok, offer}
  end

  defp validate_line_offer(changeset, %Offer{}), do: changeset

  defp validate_line_offer(changeset, nil),
    do: Ecto.Changeset.add_error(changeset, :offer_id, "does not exist")

  # DR-41: a line's service must be one of the offer's category's services.
  defp validate_line_service(changeset, offer) do
    with %Offer{category_id: category_id} <- offer,
         service_id when not is_nil(service_id) <-
           Ecto.Changeset.get_change(changeset, :service_id) do
      case Repo.get(Service, service_id) do
        %Service{category_id: ^category_id} ->
          changeset

        %Service{} ->
          Ecto.Changeset.add_error(
            changeset,
            :service_id,
            "must be a service of this offer's category"
          )

        nil ->
          Ecto.Changeset.add_error(changeset, :service_id, "does not exist")
      end
    else
      _ -> changeset
    end
  end

  defp validate_line_event(changeset) do
    case Ecto.Changeset.get_change(changeset, :event_id) do
      nil ->
        changeset

      event_id ->
        if Repo.exists?(where(Event, [e], e.id == ^event_id)),
          do: changeset,
          else: Ecto.Changeset.add_error(changeset, :event_id, "does not exist")
    end
  end

  # DR-41, CST-33: a line rate may only be *set* while the offer is VAT exclusive. A rate
  # stored earlier is retained if the offer turns inclusive (C3 ignores it, CST-36 step 5).
  defp validate_line_vat_rate(changeset, %Offer{vat_basis: :exclusive}), do: changeset

  defp validate_line_vat_rate(changeset, _offer) do
    if is_nil(Ecto.Changeset.get_change(changeset, :vat_rate_bp)) do
      changeset
    else
      Ecto.Changeset.add_error(
        changeset,
        :vat_rate_input,
        "a line VAT rate can only be set on a VAT-exclusive offer"
      )
    end
  end

  defp log_line_changes(scope, %OfferLine{} = before, %OfferLine{} = updated, changeset) do
    label = line_label(before)
    vendor = vendor_name(before.offer_id)

    @line_loggable_fields
    |> Enum.filter(&Map.has_key?(changeset.changes, &1))
    |> Enum.each(fn field ->
      old = line_field_display(field, before)
      new = line_field_display(field, updated)

      {:ok, _} =
        Log.entry(
          scope,
          {:offer, before.offer_id},
          "#{actor(scope)} changed the #{line_field_label(field)} of line '#{label}' in offer '#{vendor}': #{old} → #{new}"
        )
    end)

    :ok
  end

  defp line_field_label(:service_id), do: "service"
  defp line_field_label(:label), do: "label"
  defp line_field_label(:variation), do: "variation"
  defp line_field_label(:notes), do: "notes"
  defp line_field_label(:state), do: "state"
  defp line_field_label(:basis), do: "pricing basis"
  defp line_field_label(:event_id), do: "event"
  defp line_field_label(:amount), do: "amount"
  defp line_field_label(:included_quantity), do: "included quantity"
  defp line_field_label(:minimum_charge), do: "minimum charge"
  defp line_field_label(:vat_rate_bp), do: "VAT rate"
  defp line_field_label(:enabled), do: "on/off toggle"

  defp line_field_display(:service_id, %OfferLine{service: %Service{name: name}}), do: name
  defp line_field_display(:event_id, %OfferLine{event: %Event{name: name}}), do: name
  defp line_field_display(:state, %OfferLine{state: state}), do: state_word(state)
  defp line_field_display(:enabled, %OfferLine{enabled: true}), do: "on"
  defp line_field_display(:enabled, %OfferLine{enabled: false}), do: "off"

  defp line_field_display(field, %OfferLine{} = line) do
    case {field, Map.fetch!(line, field)} do
      {_field, nil} -> "none"
      {:basis, basis} -> basis_word(basis)
      {:vat_rate_bp, bp} -> VatRate.format(bp)
      {_money_field, %Money{} = money} -> Format.money(money)
      {_field, value} -> to_string(value)
    end
  end

  defp line_descriptor(%OfferLine{state: state, basis: basis, event: event}) do
    cond do
      not OfferLine.per_person?(basis) -> state_word(state)
      match?(%Event{}, event) -> "#{basis_word(basis)}, #{event.name}"
      true -> basis_word(basis)
    end
  end

  defp state_word(:not_offered), do: "not offered"
  defp state_word(state), do: to_string(state)

  defp basis_word(:flat), do: "flat"
  defp basis_word(:per_adult), do: "per adult"
  defp basis_word(:per_child), do: "per child"
  defp basis_word(:per_attendee), do: "per attendee"

  defp vendor_name(offer_id), do: Repo.get!(Offer, offer_id).vendor_name

  defp pluralize(1, word), do: word
  defp pluralize(_n, word), do: word <> "s"

  defp validate_category_exists(changeset) do
    category_id = Ecto.Changeset.get_field(changeset, :category_id)

    if is_nil(category_id) or Repo.exists?(where(Category, [c], c.id == ^category_id)) do
      changeset
    else
      Ecto.Changeset.add_error(changeset, :category_id, "does not exist")
    end
  end

  defp log_offer_changes(scope, %Offer{} = before, %Offer{} = updated, changeset) do
    changeset.changes
    |> Map.keys()
    |> Enum.filter(&(&1 in @loggable_fields))
    |> Enum.each(fn field ->
      old = field_display(field, Map.fetch!(before, field))
      new = field_display(field, Map.fetch!(updated, field))

      {:ok, _} =
        Log.entry(
          scope,
          {:offer, updated.id},
          "#{actor(scope)} changed the #{field_label(field)} of offer '#{before.vendor_name}': #{old} → #{new}"
        )
    end)

    :ok
  end

  defp field_label(:vendor_name), do: "vendor"
  defp field_label(:url), do: "URL"
  defp field_label(:notes), do: "notes"
  defp field_label(:status), do: "status"
  defp field_label(:vat_basis), do: "VAT basis"
  defp field_label(:vat_rate_bp), do: "VAT rate"
  defp field_label(:minimum_spend), do: "minimum spend"

  defp field_display(:url, nil), do: "none"
  defp field_display(:notes, nil), do: "none"
  defp field_display(:status, value), do: to_string(value)
  defp field_display(:vat_basis, value), do: to_string(value)
  defp field_display(:vat_rate_bp, nil), do: "none"
  defp field_display(:vat_rate_bp, bp), do: VatRate.format(bp)
  defp field_display(:minimum_spend, nil), do: "none"
  defp field_display(:minimum_spend, %Money{} = money), do: Format.money(money)
  defp field_display(_field, value), do: value

  # -- private: confirmation (C5) --------------------------------------------------------

  # DR-62, DR-66: confirm / un-confirm / planning pick re-read the offer *inside* their
  # Log.action/3 and only then write. Log.action/3's first statement is its summary INSERT,
  # which takes SQLite's single write lock (a deferred transaction whose first statement is
  # a write waits on busy_timeout for the lock), so a concurrent caller's re-read only
  # happens after the first one committed — measured in OffersConfirmationConcurrencyTest.
  # The unique pair (frozen rows) and the partial unique index (planning pick) stay the
  # backstops.

  defp confirm_and_log(scope, offer_id) do
    # DR-62: re-read inside the transaction — a concurrent confirm that won is refused.
    current = Repo.get!(Offer, offer_id)
    if current.status == :confirmed, do: Repo.rollback(:already_confirmed)

    category = Repo.get!(Category, current.category_id)
    services = Service |> where([s], s.category_id == ^category.id) |> Repo.all()

    snapshot = %Snapshot{
      services: services,
      offers: [current],
      offer_lines: OfferLine |> where([l], l.offer_id == ^current.id) |> Repo.all(),
      overrides: list_overrides(current)
    }

    # CST-40, DR-61: the single definition of what a confirmation captures.
    service_ids = Selection.freeze(snapshot, current)

    {:ok, confirmed} = current |> Offer.confirmation_changeset(true) |> Repo.update()
    :ok = log_status_change(scope, current, confirmed)

    if current.planning_pick do
      {:ok, _} =
        Log.entry(
          scope,
          {:offer, current.id},
          pick_cleared_description(scope, current, category.name, " (offer confirmed)")
        )
    end

    frozen =
      Enum.map(service_ids, fn service_id ->
        {:ok, row} =
          %FrozenService{offer_id: current.id, service_id: service_id}
          |> FrozenService.changeset()
          |> Repo.insert()

        row
      end)

    names_by_id = Map.new(services, &{&1.id, &1.name})
    names = Enum.map(service_ids, &Map.fetch!(names_by_id, &1))

    {:ok, _} =
      Log.entry(scope, {:offer, current.id}, froze_description(scope, current, names))

    cleared =
      clear_category_pick(
        scope,
        category,
        current.id,
        " (an offer in #{category.name} was confirmed)"
      )

    {Repo.preload(confirmed, :category), frozen, cleared}
  end

  defp unconfirm_and_log(scope, offer_id) do
    current = Repo.get!(Offer, offer_id)
    if current.status != :confirmed, do: Repo.rollback(:not_confirmed)
    :ok = refuse_unconfirm_while_invoiced(current)

    # DR-58: status and invoicing_complete change in the same UPDATE (the CHECK).
    {:ok, updated} = current |> Offer.confirmation_changeset(false) |> Repo.update()
    :ok = log_status_change(scope, current, updated)
    discarded = delete_frozen_services(scope, current, :unconfirmed)

    if current.invoicing_complete do
      {:ok, _} =
        Log.entry(
          scope,
          {:offer, current.id},
          "#{actor(scope)} cleared invoicing complete for offer '#{current.vendor_name}' " <>
            "(offer un-confirmed)"
        )
    end

    {Repo.preload(updated, :category), discarded}
  end

  # DR-65 (user-decided 2026-09-24, "I'd say refuse for now"): un-confirming is refused
  # while any invoice links to the offer — BUD-03 would otherwise count such an invoice
  # nowhere. This is the one place that decides; switching to DR-65's superseded "unlink
  # them" option replaces this refusal with an unlink step (one child entry per invoice)
  # inside the same Log.action/3, and `unconfirm_blockers/1` with an effect.
  defp refuse_unconfirm_while_invoiced(%Offer{} = offer) do
    if Invoices.count_invoices_by_offer(offer) > 0,
      do: Repo.rollback(:has_invoices),
      else: :ok
  end

  defp insert_frozen_service(offer_id, %Service{} = service) do
    current = Repo.get!(Offer, offer_id)

    cond do
      current.status != :confirmed ->
        Repo.rollback(:not_confirmed)

      service.category_id != current.category_id ->
        Repo.rollback(:wrong_category)

      Repo.exists?(
        from(f in FrozenService, where: f.offer_id == ^current.id and f.service_id == ^service.id)
      ) ->
        Repo.rollback(:already_in_scope)

      true ->
        case %FrozenService{offer_id: current.id, service_id: service.id}
             |> FrozenService.changeset()
             |> Repo.insert() do
          {:ok, row} -> {current, row}
          {:error, %Ecto.Changeset{}} -> Repo.rollback(:already_in_scope)
        end
    end
  end

  defp move_pick_and_log(scope, offer_id, category_name) do
    current = Repo.get!(Offer, offer_id)

    cond do
      current.status == :confirmed ->
        Repo.rollback(:confirmed)

      current.status == :rejected ->
        Repo.rollback(:rejected)

      category_has_confirmed_offer?(current.category_id) ->
        Repo.rollback(:category_has_confirmed_offer)

      current.planning_pick ->
        Repo.rollback(:already_pick)

      true ->
        # DR-66: clear the old pick first — the partial unique index allows one per category.
        cleared =
          clear_category_pick(
            scope,
            %Category{id: current.category_id, name: category_name},
            current.id,
            " (moved to offer '#{current.vendor_name}')"
          )

        {:ok, picked} = current |> Offer.planning_pick_changeset(true) |> Repo.update()

        {:ok, _} =
          Log.entry(
            scope,
            {:offer, picked.id},
            "#{actor(scope)} made offer '#{picked.vendor_name}' the planning pick for #{category_name}"
          )

        {cleared, Repo.preload(picked, :category)}
    end
  end

  # Clears the planning pick of every offer in `category` other than `except_id` (at most
  # one, the partial unique index), one entry each. Runs inside the caller's transaction.
  defp clear_category_pick(scope, %Category{} = category, except_id, suffix) do
    from(o in Offer,
      where: o.category_id == ^category.id and o.planning_pick == true and o.id != ^except_id,
      order_by: [asc: o.id]
    )
    |> Repo.all()
    |> Enum.map(fn offer ->
      {:ok, cleared} = offer |> Offer.planning_pick_changeset(false) |> Repo.update()

      {:ok, _} =
        Log.entry(
          scope,
          {:offer, cleared.id},
          pick_cleared_description(scope, cleared, category.name, suffix)
        )

      cleared
    end)
  end

  # `update_offer/3` (DR-66): rejecting the pick clears it in the same UPDATE. Forced, and
  # decided on the stored flag, so a stale struct cannot leave the CHECK to fail.
  defp clear_pick_on_reject(changeset, %Offer{id: id}) do
    rejecting? =
      Ecto.Changeset.get_change(changeset, :status) == :rejected and changeset.valid? and
        not is_nil(id)

    if rejecting? and Repo.exists?(from(o in Offer, where: o.id == ^id and o.planning_pick)) do
      Ecto.Changeset.force_change(changeset, :planning_pick, false)
    else
      changeset
    end
  end

  defp delete_frozen_services(scope, %Offer{} = offer, reason) do
    rows = list_frozen_services(offer)
    Enum.each(rows, fn row -> {:ok, _} = Repo.delete(row) end)
    n = length(rows)

    description =
      case {reason, n} do
        {:offer_deleted, 0} -> nil
        {:offer_deleted, _n} -> "(offer deleted)"
        {:unconfirmed, 0} -> "(no services)"
        {:unconfirmed, n} -> "(#{n} #{pluralize(n, "service")})"
      end

    if description do
      {:ok, _} =
        Log.entry(
          scope,
          {:offer, offer.id},
          "#{actor(scope)} discarded the confirmed scope of offer '#{offer.vendor_name}' #{description}"
        )
    end

    rows
  end

  defp frozen_services_query(%Offer{id: offer_id}) do
    where(FrozenService, [f], f.offer_id == ^offer_id)
  end

  defp log_status_change(scope, %Offer{} = before, %Offer{} = updated) do
    {:ok, _} =
      Log.entry(
        scope,
        {:offer, updated.id},
        "#{actor(scope)} changed the status of offer '#{before.vendor_name}': " <>
          "#{field_display(:status, before.status)} → #{field_display(:status, updated.status)}"
      )

    :ok
  end

  defp froze_description(scope, %Offer{vendor_name: vendor}, []),
    do: "#{actor(scope)} froze no services for offer '#{vendor}'"

  defp froze_description(scope, %Offer{vendor_name: vendor}, names) do
    n = length(names)

    "#{actor(scope)} froze #{n} #{pluralize(n, "service")} for offer '#{vendor}': " <>
      Enum.join(names, ", ")
  end

  defp pick_cleared_description(scope, %Offer{} = offer, suffix) do
    pick_cleared_description(scope, offer, Repo.get!(Category, offer.category_id).name, suffix)
  end

  defp pick_cleared_description(scope, %Offer{vendor_name: vendor}, category_name, suffix) do
    "#{actor(scope)} cleared offer '#{vendor}' as the planning pick for #{category_name}#{suffix}"
  end

  # CST-43 case 3, DR-64: an optional ad hoc toggle on a confirmed offer moves its scope.
  defp scope_suffix(%Offer{status: :confirmed}, true), do: " (added to the confirmed scope)"
  defp scope_suffix(%Offer{status: :confirmed}, false), do: " (removed from the confirmed scope)"
  defp scope_suffix(%Offer{}, _enabled), do: ""

  defp current_status!(%Offer{id: id}) do
    Repo.one!(from(o in Offer, where: o.id == ^id, select: o.status))
  end

  defp actor(%Scope{user: %User{display_name: name}}), do: name
end
