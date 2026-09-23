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
  count ("5 lines") followed by `References.reference_deletion_effects/1` under the
  offer's owner.

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
  """

  import Ecto.Query

  alias WeddingPlanner.Accounts.Scope
  alias WeddingPlanner.Accounts.User
  alias WeddingPlanner.Categories.Category
  alias WeddingPlanner.Categories.Service
  alias WeddingPlanner.Events.Event
  alias WeddingPlanner.Invoices
  alias WeddingPlanner.Log
  alias WeddingPlanner.Offers.Offer
  alias WeddingPlanner.Offers.OfferLine
  alias WeddingPlanner.Offers.Override
  alias WeddingPlanner.Offers.VatRate
  alias WeddingPlanner.Realtime
  alias WeddingPlanner.References
  alias WeddingPlanner.References.Owner
  alias WeddingPlanner.Repo
  alias WeddingPlanner.Valuation.Selection
  alias WeddingPlanner.Valuation.Snapshot
  alias WeddingPlannerWeb.Format

  @resource :offer
  @line_resource :offer_line
  @override_resource :override
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
  written.
  """
  @spec update_offer(Scope.t(), Offer.t(), map()) ::
          {:ok, Offer.t()} | {:error, Ecto.Changeset.t()}
  def update_offer(%Scope{} = scope, %Offer{} = offer, attrs) do
    changeset = change_offer(offer, attrs)

    with {:ok, updated} <- Repo.update(changeset) do
      :ok = log_offer_changes(scope, offer, updated, changeset)
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
  override on 'Sound' (offer deleted)", `DR-56`) and one per removed reference
  (`References.delete_owner_references/2`), all before the offer row itself is deleted,
  since `offer_lines.offer_id`, `offer_overrides.offer_id` and `references.offer_id` are
  all `on_delete: :restrict`. Files are purged (`References.purge_deleted/1`) only after
  the transaction commits; each line's and override's `{:deleted, id}` and then the
  offer's own are broadcast last (`XC-01`).
  """
  @spec delete_offer(Scope.t(), Offer.t()) :: {:ok, Offer.t()} | {:error, :has_invoices}
  def delete_offer(%Scope{} = scope, %Offer{} = offer) do
    if offer_deletion_blockers(offer) == [] do
      {:ok, {deleted, deleted_lines, deleted_overrides, deleted_references}} =
        Log.action(
          scope,
          "#{actor(scope)} deleted offer '#{offer.vendor_name}'",
          fn ->
            deleted_lines = delete_offer_lines(scope, offer)
            deleted_overrides = delete_offer_overrides(scope, offer)
            deleted_references = References.delete_owner_references(scope, reference_owner(offer))
            {:ok, deleted} = Repo.delete(offer)
            {deleted, deleted_lines, deleted_overrides, deleted_references}
          end
        )

      :ok = References.purge_deleted(deleted_references)
      Enum.each(deleted_lines, &Realtime.broadcast_change(@line_resource, {:deleted, &1.id}))

      Enum.each(
        deleted_overrides,
        &Realtime.broadcast_change(@override_resource, {:deleted, &1.id})
      )

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
  likewise (`DR-56`), then its references.
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

    lines ++ overrides ++ References.reference_deletion_effects(reference_owner(offer))
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

        {:ok, _} =
          Log.entry(
            scope,
            {:offer, updated.offer_id},
            "#{actor(scope)} #{verb} '#{line_label(updated)}' in offer '#{vendor_name(updated.offer_id)}'"
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
    "#{line.service.name} (#{line_descriptor(line)})"
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
  """
  @spec toggle_override(Scope.t(), Offer.t(), Service.t()) ::
          {:ok, %{wanted: boolean(), override: Override.t() | nil}}
          | {:error, :wrong_category}
  def toggle_override(%Scope{} = scope, %Offer{} = offer, %Service{} = service) do
    if service.category_id != offer.category_id do
      {:error, :wrong_category}
    else
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

  defp actor(%Scope{user: %User{display_name: name}}), do: name
end
