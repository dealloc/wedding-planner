defmodule WeddingPlanner.Offers do
  @moduledoc """
  Offers within a category (`docs/modules/offers-and-comparison.md` `CST-10`, `CST-33`,
  `CST-36`; `DR-40`), resource `:offer`, entity type `"offer"`. This is slice C2's data
  layer only: the context, its schema and its migration. Offer lines are task 50; the
  `/categories/:id` list and quick-offer form is task 51, `/offers/:id` is task 52.
  Nothing here computes a total, a gap or a formula — that is slice C3/C4 (`DR-43`).

  ## References (`DR-28`, `XC-20`–`XC-24`)

  `reference_owner/1` is the `WeddingPlanner.References.Owner` C2 promised B1:
  `%{attrs: %{offer_id: offer.id}, log_entity: {:offer, offer.id}, name: "offer
  '<vendor>'"}`. `delete_offer/2` follows the two-step contract
  `WeddingPlanner.References` documents: `References.delete_owner_references/2` runs
  **inside** the offer's own `Log.action/3`, before the offer row is deleted (the
  `references.offer_id` FK is `on_delete: :restrict`, so the references must go first);
  `References.purge_deleted/1` runs **after** the transaction commits.
  `offer_deletion_effects/1` feeds the deletion confirmation (`XC-40`) and is just
  `References.reference_deletion_effects/1` under the offer's owner — C2 adds no
  offer-specific effect of its own (no lines yet, task 50).

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
  Heers'") whose children are the reference removals (task 50 adds line removals
  alongside them).
  """

  import Ecto.Query

  alias WeddingPlanner.Accounts.Scope
  alias WeddingPlanner.Accounts.User
  alias WeddingPlanner.Categories.Category
  alias WeddingPlanner.Log
  alias WeddingPlanner.Offers.Offer
  alias WeddingPlanner.Offers.VatRate
  alias WeddingPlanner.Realtime
  alias WeddingPlanner.References
  alias WeddingPlanner.References.Owner
  alias WeddingPlanner.Repo
  alias WeddingPlannerWeb.Format

  @resource :offer

  @loggable_fields [
    :vendor_name,
    :url,
    :notes,
    :status,
    :vat_basis,
    :vat_rate_bp,
    :minimum_spend
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
  Deletes `offer` (`XC-24`): one `Log.action/3` — "Wannes deleted offer 'Kasteel Heers'"
  as the summary, one child entry per removed reference
  (`References.delete_owner_references/2`, run before the offer row itself is deleted,
  since `references.offer_id` is `on_delete: :restrict`). Files are purged
  (`References.purge_deleted/1`) only after the transaction commits, and the offer's own
  `{:deleted, id}` is broadcast last (`XC-01`).
  """
  @spec delete_offer(Scope.t(), Offer.t()) :: {:ok, Offer.t()}
  def delete_offer(%Scope{} = scope, %Offer{} = offer) do
    {:ok, {deleted, deleted_references}} =
      Log.action(
        scope,
        "#{actor(scope)} deleted offer '#{offer.vendor_name}'",
        fn ->
          deleted_references = References.delete_owner_references(scope, reference_owner(offer))
          {:ok, deleted} = Repo.delete(offer)
          {deleted, deleted_references}
        end
      )

    :ok = References.purge_deleted(deleted_references)
    Realtime.broadcast_change(@resource, {:deleted, deleted.id})
    {:ok, deleted}
  end

  @doc "What deleting `offer` removes, for the deletion confirmation (`XC-24`, `XC-40`)."
  @spec offer_deletion_effects(Offer.t()) :: [%{label: String.t(), count: non_neg_integer()}]
  def offer_deletion_effects(%Offer{} = offer) do
    References.reference_deletion_effects(reference_owner(offer))
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

  # -- private -------------------------------------------------------------------------

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
