defmodule WeddingPlanner.Invoices.InvoiceLine do
  @moduledoc """
  One line of an invoice (`docs/modules/invoices-and-budget.md` `BIL-02`, `BIL-03`;
  `docs/03-domain-model.md`'s Invoice line; `DR-59`): a label and a **static**,
  **VAT-inclusive** amount — never a formula, unlike `WeddingPlanner.Offers.OfferLine`.
  `invoice_id` is set **programmatically**, from an already-loaded invoice
  (`WeddingPlanner.Invoices.create_invoice/4`, `create_line/3`), and never cast.

  ## Amount (`DR-18`, `DR-23`, `NFR-14`)

  `amount_input` is parsed with `WeddingPlanner.Money.parse/1` only (`DR-23`): an explicit
  blank is refused (an amount is always required, `BIL-02`), never silently cleared.
  Code (seeds, fixtures, the normative-input tests) may instead pass an already-typed
  `%Money{}` in EUR under `:amount` (`DR-46` precedent) — anything else under that key,
  notably a string, is refused rather than converted (`DR-18`). Amounts are entered and
  stored already rounded (`NFR-14`) — this schema does no rounding of its own, it stores
  exactly what `WeddingPlanner.Money.parse/1` or the caller hands it.
  """
  use Ecto.Schema

  import Ecto.Changeset

  alias WeddingPlanner.Invoices.Invoice

  @type t :: %__MODULE__{}

  @label_max 200

  schema "invoice_lines" do
    belongs_to :invoice, Invoice

    field :label, :string
    field :amount, Money.Ecto.Map.Type
    field :amount_input, :string, virtual: true

    timestamps(type: :utc_datetime)
  end

  @doc """
  The structural changeset: `label` required, 1–200 characters, trimmed; `amount` required
  (via `amount_input`, or a typed `%Money{}` under `:amount` — see the moduledoc).
  """
  @spec changeset(t(), map()) :: Ecto.Changeset.t()
  def changeset(line, attrs) do
    line
    |> cast(attrs, [:label])
    |> update_change(:label, &trim/1)
    |> cast(attrs, [:amount_input], empty_values: [])
    |> put_typed_amount(attrs)
    |> put_amount_input()
    |> validate_required([:label])
    |> validate_length(:label, min: 1, max: @label_max)
    |> require_amount()
  end

  defp trim(value) when is_binary(value), do: String.trim(value)
  defp trim(value), do: value

  # The programmatic path (seeds, fixtures, the normative-input tests): an already-built
  # `%Money{}` in EUR under `:amount`. Anything else under that key — above all a string,
  # which `Money.new/2` would misread under the nl-BE locale (`DR-18`) — is refused.
  defp put_typed_amount(changeset, attrs) do
    case fetch_attr(attrs, :amount) do
      :error -> changeset
      {:ok, %Money{currency: :EUR} = money} -> put_change(changeset, :amount, money)
      {:ok, _other} -> add_error(changeset, :amount_input, "is invalid")
    end
  end

  defp fetch_attr(attrs, key) do
    case Map.fetch(attrs, key) do
      {:ok, value} -> {:ok, value}
      :error -> Map.fetch(attrs, Atom.to_string(key))
    end
  end

  defp put_amount_input(changeset) do
    case get_change(changeset, :amount_input) do
      nil ->
        changeset

      raw when is_binary(raw) ->
        case WeddingPlanner.Money.parse(raw) do
          {:ok, money} -> put_change(changeset, :amount, money)
          {:error, message} -> add_error(changeset, :amount_input, message)
        end
    end
  end

  defp require_amount(changeset) do
    if is_nil(get_field(changeset, :amount)) and
         not Keyword.has_key?(changeset.errors, :amount_input) do
      add_error(changeset, :amount_input, "can't be blank", validation: :required)
    else
      changeset
    end
  end
end
