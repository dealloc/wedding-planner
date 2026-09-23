defmodule WeddingPlanner.Invoices do
  @moduledoc """
  Invoices — what a vendor actually billed, as distinct from what was offered
  (`docs/modules/invoices-and-budget.md` `BIL-01` through `BIL-07`; `docs/04-cross-cutting.md`
  `XC-10` through `XC-12`, `XC-20` through `XC-24`, `XC-40`; `docs/06-decisions.md` `D-08`,
  `D-09`; `DR-28`, `DR-58`, `DR-59`), resource `:invoice`, entity type `"invoice"`, and their
  lines, resource `:invoice_line`. This is slice B2's data layer only; the screens are
  tasks 69/70 and the figures engine (variance, budget layers, forecast) is task 68 —
  nothing here computes anything: invoice amounts are static and stored exactly as entered
  (`BIL-03`).

  ## An invoice belongs to a category, MAY link to a confirmed offer (`D-08`, `DR-58`)

  `BIL-01`: invoices without an offer are allowed (small purchases that never had a
  quote). When linked, the offer MUST be **confirmed** and in the invoice's **own**
  category — `change_invoice/2` re-checks both on every write that touches `offer_id`
  (`WeddingPlanner.Invoices.Invoice.changeset/2` cannot do this alone, it needs a query),
  refusing with a changeset error ("only confirmed offers can be linked", or a
  category-mismatch message) rather than raising. The reverse rule — the category cannot
  change while linked — needs no query and lives in the schema's own changeset.
  `BIL-04`: an offer may have several invoices.

  ## Paid (`BIL-02`) and invoicing complete (`BIL-05`)

  An invoice's paid flag is derived from `paid_on` (`Invoice.paid?/1`); `mark_paid/3` and
  `mark_unpaid/2` are the dedicated entry points with their own log wording (`XC-10`),
  distinct from an ordinary edit of the paid date on an already-paid invoice (which goes
  through `update_invoice/3` like any other field). `set_invoicing_complete/3` is the
  confirmed offer's own flag (`offers.invoicing_complete`, `DR-58`): refused unless the
  offer is confirmed, logged against the **offer**, broadcasting `:offer`. The column CHECK
  `offers_invoicing_complete_requires_confirmed` is the backstop against a raw `UPDATE`.

  ## Lines (`BIL-02`, `BIL-03`, `DR-59`)

  Every invoice has **at least one** line (label + static, VAT-inclusive amount) —
  `create_invoice/4` inserts the invoice and its first line together, in one
  `Log.action/3`, and `delete_line/2` refuses to remove the last one
  (`{:error, :last_line}`). Amounts go through `WeddingPlanner.Invoices.InvoiceLine`'s
  `amount_input` (`WeddingPlanner.Money.parse/1`, `DR-23`) or, for code, an already-typed
  `%Money{}` (`DR-46` precedent) — never a raw string (`DR-18`).

  ## References (`DR-28`, `XC-20`–`XC-24`)

  `reference_owner/1` is the `WeddingPlanner.References.Owner` B2 promised B1/C2:
  `%{attrs: %{invoice_id: invoice.id}, log_entity: {:invoice, invoice.id}, name: "invoice
  '<label>'"}`. `delete_invoice/2` follows the same two-step contract
  `WeddingPlanner.Offers.delete_offer/2` does: `References.delete_owner_references/2` runs
  **inside** the invoice's own `Log.action/3`, before the invoice row is deleted (lines
  first too — both `invoice_lines.invoice_id` and `references.invoice_id` are
  `on_delete: :restrict`); `References.purge_deleted/1` runs **after** commit.
  `invoice_deletion_effects/1` feeds the deletion confirmation (`XC-40`): the invoice's
  line count, then `References.reference_deletion_effects/1`.

  ## Activity log (`XC-10`) and PubSub (`XC-01`)

  Every mutation writes through `WeddingPlanner.Log` and broadcasts the whole resulting
  record via `WeddingPlanner.Realtime` (`:invoice`, `:invoice_line`) only after its write
  succeeds. `update_invoice/3` logs one entry per changed field (label, invoice date, due
  date, paid date, category, offer link); line creates/updates/deletes are logged against
  the **invoice** (`{:invoice, id}`), naming the line by its label plus, on create, its
  amount ("added line 'Deposit' (€ 3.000,00) to invoice 'Venue deposit'").

  ## Seams into other contexts

    * `count_invoices/1` is `WeddingPlanner.Categories.category_deletion_blockers/1`'s
      `DR-26` Q11 invoice half.
    * `count_invoices_by_offer/1` is `WeddingPlanner.Offers.offer_deletion_blockers/1`
      (`DR-58`): an offer with linked invoices cannot be deleted.
  """

  import Ecto.Query

  alias WeddingPlanner.Accounts.Scope
  alias WeddingPlanner.Accounts.User
  alias WeddingPlanner.Categories.Category
  alias WeddingPlanner.Invoices.Invoice
  alias WeddingPlanner.Invoices.InvoiceLine
  alias WeddingPlanner.Log
  alias WeddingPlanner.Offers.Offer
  alias WeddingPlanner.Realtime
  alias WeddingPlanner.References
  alias WeddingPlanner.References.Owner
  alias WeddingPlanner.Repo
  alias WeddingPlannerWeb.Format

  @resource :invoice
  @line_resource :invoice_line

  @loggable_fields [:label, :invoice_date, :due_date, :paid_on, :category_id, :offer_id]
  @line_loggable_fields [:label, :amount]

  # -- Invoices --------------------------------------------------------------------------

  @doc "Every invoice, oldest first (`id`), lines preloaded in id order."
  @spec list_invoices() :: [Invoice.t()]
  def list_invoices do
    Invoice
    |> order_by([i], asc: i.id)
    |> preload(lines: ^lines_query())
    |> Repo.all()
  end

  @doc "A category's invoices, oldest first (`id`), lines preloaded in id order."
  @spec list_invoices(Category.t() | term()) :: [Invoice.t()]
  def list_invoices(%Category{id: category_id}), do: list_invoices(category_id)

  def list_invoices(category_id) do
    Invoice
    |> where([i], i.category_id == ^category_id)
    |> order_by([i], asc: i.id)
    |> preload(lines: ^lines_query())
    |> Repo.all()
  end

  @doc "An offer's linked invoices, oldest first (`id`), lines preloaded in id order (`BIL-04`)."
  @spec list_invoices_by_offer(Offer.t()) :: [Invoice.t()]
  def list_invoices_by_offer(%Offer{id: offer_id}) do
    Invoice
    |> where([i], i.offer_id == ^offer_id)
    |> order_by([i], asc: i.id)
    |> preload(lines: ^lines_query())
    |> Repo.all()
  end

  @doc "Fetches one invoice by id, lines preloaded in id order. Raises if it does not exist."
  @spec get_invoice!(term()) :: Invoice.t()
  def get_invoice!(id) do
    Invoice |> Repo.get!(id) |> Repo.preload(lines: lines_query())
  end

  @doc """
  A changeset for building/validating an invoice form (create or edit) — never persists on
  its own. Adds the query-backed checks `WeddingPlanner.Invoices.Invoice.changeset/2`
  cannot make alone (see the moduledoc): the category exists, and a linked offer is
  confirmed and in this invoice's own category (`DR-58`).
  """
  @spec change_invoice(Invoice.t(), map()) :: Ecto.Changeset.t()
  def change_invoice(%Invoice{} = invoice, attrs \\ %{}) do
    invoice
    |> Invoice.changeset(attrs)
    |> validate_category_exists()
    |> validate_offer_link()
  end

  @doc """
  Creates an invoice in `category` with its first line, in one `Log.action/3`: the summary
  is "Wannes added invoice 'Venue deposit' to Venue", its one child entry is the line
  ("Wannes added line 'Deposit' (€ 3.000,00) to invoice 'Venue deposit'"). Broadcasts
  `{:created, invoice}` on `:invoice` and `{:created, line}` on `:invoice_line` after
  commit. If either the invoice or the first line's attrs are invalid, **nothing is
  written** — the error is the invoice's changeset, carrying the line's `amount_input`
  error too (`WeddingPlanner.Offers.create_simple_offer/3` precedent), so one short form
  can show both.
  """
  @spec create_invoice(Scope.t(), Category.t(), map(), map()) ::
          {:ok, Invoice.t()} | {:error, Ecto.Changeset.t()}
  def create_invoice(%Scope{} = scope, %Category{} = category, attrs, first_line_attrs) do
    invoice_changeset = change_invoice(%Invoice{category_id: category.id}, attrs)
    line_changeset = InvoiceLine.changeset(%InvoiceLine{}, first_line_attrs)

    if invoice_changeset.valid? and line_changeset.valid? do
      insert_invoice(scope, category, invoice_changeset, line_changeset)
    else
      changeset =
        Enum.reduce(line_changeset.errors, invoice_changeset, fn {field, {message, opts}}, acc ->
          Ecto.Changeset.add_error(acc, field, message, opts)
        end)

      {:error, %{changeset | action: :insert}}
    end
  end

  @doc """
  Updates an invoice's fields — label, invoice date, due date, paid date, category, offer
  link. Logs one activity entry per changed field (`XC-10`), e.g. "Wannes changed the
  offer link of invoice 'Venue deposit': none → Kasteel Heers". Broadcasts
  `{:updated, invoice}` (`XC-01`) once, after every log entry is written.
  """
  @spec update_invoice(Scope.t(), Invoice.t(), map()) ::
          {:ok, Invoice.t()} | {:error, Ecto.Changeset.t()}
  def update_invoice(%Scope{} = scope, %Invoice{} = invoice, attrs) do
    before = Repo.preload(invoice, [:category, :offer], force: true)
    changeset = change_invoice(before, attrs)

    with {:ok, updated} <- Repo.update(changeset) do
      updated = Repo.preload(updated, [:category, :offer], force: true)
      :ok = log_invoice_changes(scope, before, updated, changeset)
      Realtime.broadcast_change(@resource, {:updated, updated})
      {:ok, updated}
    end
  end

  @doc """
  Marks `invoice` paid as of `date` (`BIL-02`). Logs the exact `XC-10` wording: "Wannes
  marked invoice 'Venue deposit' as paid". Broadcasts `{:updated, invoice}`.
  """
  @spec mark_paid(Scope.t(), Invoice.t(), Date.t()) :: {:ok, Invoice.t()}
  def mark_paid(%Scope{} = scope, %Invoice{} = invoice, %Date{} = date) do
    {:ok, updated} = invoice |> Invoice.paid_changeset(date) |> Repo.update()

    {:ok, _} =
      Log.entry(
        scope,
        {:invoice, updated.id},
        "#{actor(scope)} marked invoice '#{updated.label}' as paid"
      )

    Realtime.broadcast_change(@resource, {:updated, updated})
    {:ok, updated}
  end

  @doc """
  Clears `invoice`'s paid date (`BIL-02`). Logs "Wannes marked invoice 'Venue deposit' as
  unpaid". Broadcasts `{:updated, invoice}`.
  """
  @spec mark_unpaid(Scope.t(), Invoice.t()) :: {:ok, Invoice.t()}
  def mark_unpaid(%Scope{} = scope, %Invoice{} = invoice) do
    {:ok, updated} = invoice |> Invoice.paid_changeset(nil) |> Repo.update()

    {:ok, _} =
      Log.entry(
        scope,
        {:invoice, updated.id},
        "#{actor(scope)} marked invoice '#{updated.label}' as unpaid"
      )

    Realtime.broadcast_change(@resource, {:updated, updated})
    {:ok, updated}
  end

  @doc """
  Deletes `invoice` (`XC-24`): one `Log.action/3` — a summary ("Wannes deleted invoice
  'Venue deposit'"), one child entry per deleted line and one per removed reference
  (`References.delete_owner_references/2`), all before the invoice row itself is deleted,
  since `invoice_lines.invoice_id` and `references.invoice_id` are both
  `on_delete: :restrict`. Files are purged (`References.purge_deleted/1`) only after the
  transaction commits; each line's `{:deleted, id}` and then the invoice's own are
  broadcast last (`XC-01`).
  """
  @spec delete_invoice(Scope.t(), Invoice.t()) :: {:ok, Invoice.t()}
  def delete_invoice(%Scope{} = scope, %Invoice{} = invoice) do
    {:ok, {deleted, deleted_lines, deleted_references}} =
      Log.action(
        scope,
        "#{actor(scope)} deleted invoice '#{invoice.label}'",
        fn ->
          deleted_lines = delete_invoice_lines(scope, invoice)
          deleted_references = References.delete_owner_references(scope, reference_owner(invoice))
          {:ok, deleted} = Repo.delete(invoice)
          {deleted, deleted_lines, deleted_references}
        end
      )

    :ok = References.purge_deleted(deleted_references)
    Enum.each(deleted_lines, &Realtime.broadcast_change(@line_resource, {:deleted, &1.id}))
    Realtime.broadcast_change(@resource, {:deleted, deleted.id})
    {:ok, deleted}
  end

  @doc """
  What deleting `invoice` removes, for the deletion confirmation (`XC-24`, `XC-40`): its
  line count (`%{label: "3 lines", count: 3}`), then its references
  (`References.reference_deletion_effects/1`).
  """
  @spec invoice_deletion_effects(Invoice.t()) :: [%{label: String.t(), count: non_neg_integer()}]
  def invoice_deletion_effects(%Invoice{} = invoice) do
    lines =
      case InvoiceLine |> where([l], l.invoice_id == ^invoice.id) |> Repo.aggregate(:count) do
        0 -> []
        n -> [%{label: "#{n} #{pluralize(n, "line")}", count: n}]
      end

    lines ++ References.reference_deletion_effects(reference_owner(invoice))
  end

  @doc "The `WeddingPlanner.References.Owner` B2 promised B1/C2 (`DR-28`)."
  @spec reference_owner(Invoice.t()) :: Owner.t()
  def reference_owner(%Invoice{} = invoice) do
    %Owner{
      attrs: %{invoice_id: invoice.id},
      log_entity: {:invoice, invoice.id},
      name: "invoice '#{invoice.label}'"
    }
  end

  @doc "How many invoices `category` has — `WeddingPlanner.Categories.category_deletion_blockers/1`'s `DR-26` Q11 check."
  @spec count_invoices(Category.t()) :: non_neg_integer()
  def count_invoices(%Category{id: category_id}) do
    Invoice |> where([i], i.category_id == ^category_id) |> Repo.aggregate(:count)
  end

  @doc "How many invoices link to `offer` — `WeddingPlanner.Offers.offer_deletion_blockers/1`'s `DR-58` check."
  @spec count_invoices_by_offer(Offer.t()) :: non_neg_integer()
  def count_invoices_by_offer(%Offer{id: offer_id}) do
    Invoice |> where([i], i.offer_id == ^offer_id) |> Repo.aggregate(:count)
  end

  @doc """
  `WeddingPlanner.Log.EntityRef` resolver for the `"invoice"` entity type: an existing
  invoice resolves to its label and `/invoices/<id>` (task 69). A deleted invoice is
  `:error` (degrades to plain text).
  """
  @spec resolve_log_entity(term()) :: {:ok, String.t(), String.t() | nil} | :error
  def resolve_log_entity(id) do
    case Repo.get(Invoice, id) do
      nil -> :error
      invoice -> {:ok, invoice.label, "/invoices/#{invoice.id}"}
    end
  end

  @doc """
  Sets or clears the confirmed offer's `invoicing_complete` flag (`BIL-05`, `DR-58`).
  `{:error, :not_confirmed}` unless `offer.status == :confirmed`. Logs against the
  **offer** — "Wannes marked invoicing complete for offer 'Venue A'" / "Wannes marked
  invoicing not complete for offer 'Venue A'" — and broadcasts `{:updated, offer}` on
  `:offer`.
  """
  @spec set_invoicing_complete(Scope.t(), Offer.t(), boolean()) ::
          {:ok, Offer.t()} | {:error, :not_confirmed}
  def set_invoicing_complete(%Scope{} = scope, %Offer{} = offer, complete)
      when is_boolean(complete) do
    if offer.status == :confirmed do
      {:ok, updated} = offer |> Offer.invoicing_complete_changeset(complete) |> Repo.update()

      verb =
        if complete,
          do: "marked invoicing complete for offer",
          else: "marked invoicing not complete for offer"

      {:ok, _} =
        Log.entry(scope, {:offer, updated.id}, "#{actor(scope)} #{verb} '#{updated.vendor_name}'")

      Realtime.broadcast_change(:offer, {:updated, updated})
      {:ok, updated}
    else
      {:error, :not_confirmed}
    end
  end

  # -- Invoice lines (DR-59) --------------------------------------------------------------

  @doc "Fetches one line by id. Raises `Ecto.NoResultsError` if it does not exist."
  @spec get_line!(term()) :: InvoiceLine.t()
  def get_line!(id), do: Repo.get!(InvoiceLine, id)

  @doc "A changeset for building/validating a line form — never persists on its own."
  @spec change_line(InvoiceLine.t(), map()) :: Ecto.Changeset.t()
  def change_line(%InvoiceLine{} = line, attrs \\ %{}), do: InvoiceLine.changeset(line, attrs)

  @doc """
  Adds a line to `invoice`. Logs "Wannes added line 'Deposit' (€ 3.000,00) to invoice
  'Venue deposit'" against the invoice (`XC-10`) and broadcasts `{:created, line}` on
  `:invoice_line` (`XC-01`).
  """
  @spec create_line(Scope.t(), Invoice.t(), map()) ::
          {:ok, InvoiceLine.t()} | {:error, Ecto.Changeset.t()}
  def create_line(%Scope{} = scope, %Invoice{} = invoice, attrs) do
    with {:ok, line} <-
           %InvoiceLine{invoice_id: invoice.id} |> change_line(attrs) |> Repo.insert() do
      {:ok, _} =
        Log.entry(
          scope,
          {:invoice, invoice.id},
          "#{actor(scope)} added line '#{line.label}' (#{Format.money(line.amount)}) to invoice '#{invoice.label}'"
        )

      Realtime.broadcast_change(@line_resource, {:created, line})
      {:ok, line}
    end
  end

  @doc """
  Updates a line. Logs one entry per changed field against the invoice (`XC-10`), e.g.
  "Wannes changed the amount of line 'Deposit' in invoice 'Venue deposit': € 3.000,00 →
  € 3.200,00". Broadcasts `{:updated, line}` once.
  """
  @spec update_line(Scope.t(), InvoiceLine.t(), map()) ::
          {:ok, InvoiceLine.t()} | {:error, Ecto.Changeset.t()}
  def update_line(%Scope{} = scope, %InvoiceLine{} = line, attrs) do
    changeset = change_line(line, attrs)

    with {:ok, updated} <- Repo.update(changeset) do
      :ok = log_line_changes(scope, line, updated, changeset)
      Realtime.broadcast_change(@line_resource, {:updated, updated})
      {:ok, updated}
    end
  end

  @doc """
  Deletes a line. Refuses to delete the invoice's **last** line
  (`{:error, :last_line}`, `BIL-02`: an invoice always has at least one). Otherwise logs
  "Wannes deleted line 'Cleaning fee' from invoice 'Venue deposit'" against the invoice
  (`XC-10`) and broadcasts `{:deleted, id}` (`XC-01`).
  """
  @spec delete_line(Scope.t(), InvoiceLine.t()) :: {:ok, InvoiceLine.t()} | {:error, :last_line}
  def delete_line(%Scope{} = scope, %InvoiceLine{} = line) do
    count = InvoiceLine |> where([l], l.invoice_id == ^line.invoice_id) |> Repo.aggregate(:count)

    if count <= 1 do
      {:error, :last_line}
    else
      {:ok, deleted} = Repo.delete(line)
      label = invoice_label(deleted.invoice_id)

      {:ok, _} =
        Log.entry(
          scope,
          {:invoice, deleted.invoice_id},
          "#{actor(scope)} deleted line '#{deleted.label}' from invoice '#{label}'"
        )

      Realtime.broadcast_change(@line_resource, {:deleted, deleted.id})
      {:ok, deleted}
    end
  end

  # -- private -------------------------------------------------------------------------

  defp lines_query, do: from(l in InvoiceLine, order_by: [asc: l.id])

  defp insert_invoice(scope, category, invoice_changeset, line_changeset) do
    label = Ecto.Changeset.get_field(invoice_changeset, :label)

    {:ok, {invoice, line}} =
      Log.action(
        scope,
        "#{actor(scope)} added invoice '#{label}' to #{category.name}",
        fn ->
          {:ok, invoice} = Repo.insert(invoice_changeset)

          {:ok, line} =
            line_changeset
            |> Ecto.Changeset.put_change(:invoice_id, invoice.id)
            |> Repo.insert()

          {:ok, _} =
            Log.entry(
              scope,
              {:invoice, invoice.id},
              "#{actor(scope)} added line '#{line.label}' (#{Format.money(line.amount)}) to invoice '#{invoice.label}'"
            )

          {invoice, line}
        end
      )

    invoice = Repo.preload(invoice, lines: lines_query())
    Realtime.broadcast_change(@resource, {:created, invoice})
    Realtime.broadcast_change(@line_resource, {:created, line})
    {:ok, invoice}
  end

  defp delete_invoice_lines(scope, %Invoice{} = invoice) do
    InvoiceLine
    |> where([l], l.invoice_id == ^invoice.id)
    |> order_by([l], asc: l.id)
    |> Repo.all()
    |> Enum.map(fn line ->
      {:ok, deleted} = Repo.delete(line)

      {:ok, _} =
        Log.entry(
          scope,
          {:invoice, invoice.id},
          "#{actor(scope)} deleted line '#{deleted.label}' from invoice '#{invoice.label}' (invoice deleted)"
        )

      deleted
    end)
  end

  defp validate_category_exists(changeset) do
    category_id = Ecto.Changeset.get_field(changeset, :category_id)

    if is_nil(category_id) or Repo.exists?(where(Category, [c], c.id == ^category_id)) do
      changeset
    else
      Ecto.Changeset.add_error(changeset, :category_id, "does not exist")
    end
  end

  # DR-58: only re-checked on a write that actually touches `offer_id` — an update that
  # leaves it alone (even if it is already set) never re-validates it, same "only on
  # writes that touch it" contract as `WeddingPlanner.Offers.OfferLine`'s event check.
  defp validate_offer_link(changeset) do
    if Map.has_key?(changeset.changes, :offer_id) do
      case Ecto.Changeset.get_field(changeset, :offer_id) do
        nil -> changeset
        offer_id -> check_offer_link(changeset, offer_id)
      end
    else
      changeset
    end
  end

  defp check_offer_link(changeset, offer_id) do
    category_id = Ecto.Changeset.get_field(changeset, :category_id)

    case Repo.get(Offer, offer_id) do
      nil ->
        Ecto.Changeset.add_error(changeset, :offer_id, "does not exist")

      %Offer{status: :confirmed, category_id: ^category_id} ->
        changeset

      %Offer{status: :confirmed} ->
        Ecto.Changeset.add_error(changeset, :offer_id, "must be in the invoice's own category")

      %Offer{} ->
        Ecto.Changeset.add_error(changeset, :offer_id, "only confirmed offers can be linked")
    end
  end

  defp log_invoice_changes(scope, %Invoice{} = before, %Invoice{} = updated, changeset) do
    changeset.changes
    |> Map.keys()
    |> Enum.filter(&(&1 in @loggable_fields))
    |> Enum.each(fn field ->
      old = invoice_field_display(field, before)
      new = invoice_field_display(field, updated)

      {:ok, _} =
        Log.entry(
          scope,
          {:invoice, updated.id},
          "#{actor(scope)} changed the #{invoice_field_label(field)} of invoice '#{before.label}': #{old} → #{new}"
        )
    end)

    :ok
  end

  defp invoice_field_label(:label), do: "label"
  defp invoice_field_label(:invoice_date), do: "invoice date"
  defp invoice_field_label(:due_date), do: "due date"
  defp invoice_field_label(:paid_on), do: "paid date"
  defp invoice_field_label(:category_id), do: "category"
  defp invoice_field_label(:offer_id), do: "offer link"

  defp invoice_field_display(:label, %Invoice{label: label}), do: label
  defp invoice_field_display(:invoice_date, %Invoice{invoice_date: date}), do: Format.date(date)
  defp invoice_field_display(:due_date, %Invoice{due_date: date}), do: Format.date(date)
  defp invoice_field_display(:paid_on, %Invoice{paid_on: date}), do: Format.date(date)
  defp invoice_field_display(:category_id, %Invoice{category: %Category{name: name}}), do: name
  defp invoice_field_display(:offer_id, %Invoice{offer: nil}), do: "none"
  defp invoice_field_display(:offer_id, %Invoice{offer: %Offer{vendor_name: vendor}}), do: vendor

  defp log_line_changes(scope, %InvoiceLine{} = before, %InvoiceLine{} = updated, changeset) do
    label = before.label
    invoice_label = invoice_label(before.invoice_id)

    @line_loggable_fields
    |> Enum.filter(&Map.has_key?(changeset.changes, &1))
    |> Enum.each(fn field ->
      old = line_field_display(field, before)
      new = line_field_display(field, updated)

      {:ok, _} =
        Log.entry(
          scope,
          {:invoice, before.invoice_id},
          "#{actor(scope)} changed the #{line_field_label(field)} of line '#{label}' in invoice '#{invoice_label}': #{old} → #{new}"
        )
    end)

    :ok
  end

  defp line_field_label(:label), do: "label"
  defp line_field_label(:amount), do: "amount"

  defp line_field_display(:label, %InvoiceLine{label: label}), do: label
  defp line_field_display(:amount, %InvoiceLine{amount: amount}), do: Format.money(amount)

  defp invoice_label(invoice_id), do: Repo.get!(Invoice, invoice_id).label

  defp pluralize(1, word), do: word
  defp pluralize(_n, word), do: word <> "s"

  defp actor(%Scope{user: %User{display_name: name}}), do: name
end
