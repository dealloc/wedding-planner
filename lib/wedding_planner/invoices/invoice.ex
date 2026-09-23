defmodule WeddingPlanner.Invoices.Invoice do
  @moduledoc """
  What a vendor actually billed (`docs/modules/invoices-and-budget.md` `BIL-01` through
  `BIL-05`; `docs/03-domain-model.md`'s Invoice entity; `D-08`, `DR-58`, `DR-59`): a
  category, an optional link to a **confirmed** offer of that same category, a label, an
  invoice date, an optional due date, a derived paid flag, and one or more lines
  (`WeddingPlanner.Invoices.InvoiceLine`). An offer and its invoices are deliberately
  separate (`D-08`): an offer's own lines are never touched by anything here.

  `category_id` and `offer_id` are, unlike `WeddingPlanner.Offers.Offer.category_id`, both
  user-editable fields (a category picked from a dropdown, an offer picked to link) — the
  same "cast here, query-backed checks live in the context" split
  `WeddingPlanner.Offers.OfferLine` uses for `service_id`/`event_id`.
  `WeddingPlanner.Invoices.change_invoice/2` adds the checks this changeset cannot make on
  its own (the category exists; a linked offer is confirmed and belongs to this invoice's
  own category, `DR-58`). This changeset alone only enforces the one rule that needs no
  query: **the category cannot change while the invoice is linked to an offer** — a write
  that touches `category_id` while the resulting `offer_id` is not `nil` is refused.
  Unlinking (`offer_id` cleared) and re-categorising may happen in the same write.

  ## Paid (`BIL-02`)

  There is no stored boolean: `paid?/1` derives it from `paid_on` being set.
  `paid_changeset/2` is the dedicated changeset `WeddingPlanner.Invoices.mark_paid/3` and
  `mark_unpaid/2` use to set or clear it with their own log wording (`XC-10`); an ordinary
  edit of the paid date on an already-paid invoice goes through the general
  `changeset/2`/`update_invoice/3` path instead, logged like any other field.
  """
  use Ecto.Schema

  import Ecto.Changeset

  alias WeddingPlanner.Categories.Category
  alias WeddingPlanner.Invoices.InvoiceLine
  alias WeddingPlanner.Offers.Offer

  @type t :: %__MODULE__{}

  @label_max 200

  schema "invoices" do
    belongs_to :category, Category
    belongs_to :offer, Offer

    field :label, :string
    field :invoice_date, :date
    field :due_date, :date
    field :paid_on, :date

    has_many :lines, InvoiceLine

    timestamps(type: :utc_datetime)
  end

  @doc "Whether `invoice` is paid — derived from `paid_on` being set (`BIL-02`)."
  @spec paid?(t()) :: boolean()
  def paid?(%__MODULE__{paid_on: nil}), do: false
  def paid?(%__MODULE__{}), do: true

  @doc """
  The structural changeset (`BIL-02`): `label` required, 1–200 characters, trimmed;
  `invoice_date` required; `due_date` and `paid_on` are plain optional dates.
  `category_id` and `offer_id` are cast (see the moduledoc); the only rule enforced here
  without a query is that `category_id` cannot change while the resulting `offer_id` is
  not `nil` (`DR-59`) — `WeddingPlanner.Invoices.change_invoice/2` adds the rest.
  """
  @spec changeset(t(), map()) :: Ecto.Changeset.t()
  def changeset(invoice, attrs) do
    invoice
    |> cast(attrs, [:label, :invoice_date, :due_date, :paid_on, :category_id, :offer_id])
    |> update_change(:label, &trim/1)
    |> validate_required([:label, :invoice_date])
    |> validate_length(:label, min: 1, max: @label_max)
    |> validate_category_locked_while_linked()
  end

  @doc "Sets or clears `paid_on` (`BIL-02`) — only `WeddingPlanner.Invoices.mark_paid/3` and `mark_unpaid/2` use this."
  @spec paid_changeset(t(), Date.t() | nil) :: Ecto.Changeset.t()
  def paid_changeset(%__MODULE__{} = invoice, paid_on) do
    change(invoice, paid_on: paid_on)
  end

  defp trim(value) when is_binary(value), do: String.trim(value)
  defp trim(value), do: value

  # DR-59: a linked invoice's category cannot change out from under its offer. `offer_id`
  # here is the *resulting* value (changed or not); unlinking and re-categorising in the
  # same write is fine because the resulting `offer_id` is then `nil`.
  defp validate_category_locked_while_linked(changeset) do
    if Map.has_key?(changeset.changes, :category_id) and
         not is_nil(get_field(changeset, :offer_id)) do
      add_error(changeset, :category_id, "cannot be changed while linked to an offer")
    else
      changeset
    end
  end
end
