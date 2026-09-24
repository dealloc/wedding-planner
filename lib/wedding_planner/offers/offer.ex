defmodule WeddingPlanner.Offers.Offer do
  @moduledoc """
  A vendor's offer within a category (`docs/modules/offers-and-comparison.md` `CST-10`,
  `CST-33`, `CST-36`; `docs/03-domain-model.md`'s Offer entity; `DR-40`): a vendor name,
  optional URL, notes, status, VAT basis with its default rate, and an optional minimum
  spend. Offer lines live in `WeddingPlanner.Offers.OfferLine` (`DR-41`); nothing here
  computes a total, formula or gap (`DR-43`) — `WeddingPlanner.Valuation` does.

  ## Planning pick and frozen selection (`CST-40`, `CST-44`, `DR-61`, `DR-66`)

  `planning_pick` (below) and the frozen selection, stored as
  `WeddingPlanner.Offers.FrozenService` rows (one per frozen-in service) and read by
  `WeddingPlanner.Valuation.Selection` for a confirmed offer. Neither is written through
  `changeset/2`: `planning_pick` is deliberately not castable, and the writes — confirming
  (which freezes), un-confirming, setting and clearing the pick — live in
  `WeddingPlanner.Offers` (`confirm_offer/2`, `unconfirm_offer/2`, `set_planning_pick/2`,
  `clear_planning_pick/2`), through the two small changesets below
  (`confirmation_changeset/2`, `planning_pick_changeset/2`).

  `planning_pick` marks the one offer per category used for planning while the category
  has no confirmed offer (`CST-44`, `D-22`). The column CHECK
  `offers_planning_pick_requires_open_status` refuses it on a confirmed or rejected offer,
  and the partial unique index `offers_one_planning_pick_per_category` allows one per
  category.

  ## Invoicing complete (`docs/modules/invoices-and-budget.md` `BIL-05`, `DR-58`)

  `invoicing_complete` is a confirmed offer's own flag, set when its final invoice has
  been received. It is deliberately absent from `changeset/2`'s cast list — the only way
  to set it is `WeddingPlanner.Invoices.set_invoicing_complete/3` (via
  `invoicing_complete_changeset/2`), which refuses unless the offer is confirmed. The
  column CHECK `offers_invoicing_complete_requires_confirmed` backs this up against a raw
  `UPDATE`.

  `category_id` is set **programmatically**, from an already-loaded `Category`, by
  `WeddingPlanner.Offers.create_offer/3` — it is deliberately absent from `changeset/2`'s
  cast list so it can never be set through a form, same as `Categories.Service`'s own
  `category_id`.

  ## VAT basis and rate (`CST-33`, `DR-40`)

  `vat_basis` is `:inclusive` (default) or `:exclusive`. `vat_rate_bp` is the offer's
  default VAT rate stored as an integer in **hundredths of a percent** (`2100` = 21 %,
  `WeddingPlanner.Offers.VatRate`) so SQLite never stores a float — never read or written
  directly by user input; `vat_rate_input` (virtual) carries whatever the user typed,
  parsed by `VatRate.parse/1`.

  Switching `vat_basis` to `:exclusive` **requires** a rate: an omitted or blank
  `vat_rate_input` is refused with "can't be blank" on that field (the form itself
  prefills 21 % so this is rarely hit in practice). Switching to `:inclusive`
  **clears** `vat_rate_bp` back to `nil`, whatever `vat_rate_input` carries — the DB CHECK
  ties the two together (`vat_basis = 'exclusive' <=> vat_rate_bp IS NOT NULL`) and this
  changeset is what keeps the stored row satisfying it before the write ever reaches the
  database. Once cleared, the field is a genuine `nil`, which
  `WeddingPlanner.Offers.log_offer_changes/3`-style per-field logging (in the context)
  renders as "none".

  ## Minimum spend (`CST-10`, `CST-36`)

  `minimum_spend_input` follows exactly `WeddingPlanner.Categories.Category`'s
  `target_input` pattern (see that module's moduledoc): parsed via
  `WeddingPlanner.Money.parse/1` (`DR-23`), an explicit empty string clears
  `minimum_spend` back to `nil`, an omitted key leaves it untouched. It is **always VAT
  inclusive** (`CST-36`) — nothing here enforces that; it is simply what the stored value
  means, and C3's total computation relies on it.

  ## Status and `confirmed` (`CST-40`, `CST-42`, `DR-40`)

  `status` is `:considering` (default), `:shortlisted`, `:rejected` or `:confirmed`.
  `changeset/2` only ever moves it among the first three: moving a status **to** or
  **from** `:confirmed` is refused with a changeset error ("Use Confirm / Un-confirm —
  confirming freezes the offer's selection (CST-40)"), because confirming must also
  freeze the selection and un-confirming must discard it (`DR-62`). Only
  `WeddingPlanner.Offers.confirm_offer/2` and `unconfirm_offer/2` move it, via
  `confirmation_changeset/2`.

  ## URL (`DR-29`)

  Optional; when present, must be `http` or `https` with a host — the exact rule
  `WeddingPlanner.References.Reference.url_changeset/2` applies, duplicated here rather
  than shared because references have no dependency on offers (`DR-28`).
  """
  use Ecto.Schema

  import Ecto.Changeset

  alias WeddingPlanner.Categories.Category
  alias WeddingPlanner.Offers.VatRate

  @type t :: %__MODULE__{}

  @vendor_name_max 200
  @url_max 2000
  @statuses [:considering, :shortlisted, :rejected, :confirmed]
  @vat_bases [:inclusive, :exclusive]

  @confirmed_message "Use Confirm / Un-confirm — confirming freezes the offer's selection (CST-40)"

  schema "offers" do
    belongs_to :category, Category

    field :vendor_name, :string
    field :url, :string
    field :notes, :string
    field :status, Ecto.Enum, values: @statuses, default: :considering
    field :vat_basis, Ecto.Enum, values: @vat_bases, default: :inclusive
    field :vat_rate_bp, :integer
    field :vat_rate_input, :string, virtual: true
    field :minimum_spend, Money.Ecto.Map.Type
    field :minimum_spend_input, :string, virtual: true
    field :invoicing_complete, :boolean, default: false
    # CST-44, DR-66: not castable — see the moduledoc.
    field :planning_pick, :boolean, default: false

    timestamps(type: :utc_datetime)
  end

  @doc """
  Changeset for the user-facing fields (`CST-10`). `vendor_name` required, 1–200
  characters, trimmed. `url`, when present, must be `http`/`https` with a host
  (`DR-29`). `status` may move freely among *considering*/*shortlisted*/*rejected*, but
  never to or from *confirmed* (see moduledoc). `vat_rate_input` and
  `minimum_spend_input` are parsed as described in the moduledoc. `category_id` is
  intentionally not castable — see `sort_order_changeset/2`-style precedent in
  `WeddingPlanner.Categories.Category`.
  """
  @spec changeset(t(), map()) :: Ecto.Changeset.t()
  def changeset(offer, attrs) do
    offer
    |> cast(attrs, [:vendor_name, :url, :notes, :status, :vat_basis])
    |> update_change(:vendor_name, &trim/1)
    |> validate_required([:vendor_name])
    |> validate_length(:vendor_name, min: 1, max: @vendor_name_max)
    |> validate_url()
    |> reject_confirmed_transition(offer)
    |> cast(attrs, [:vat_rate_input], empty_values: [])
    |> put_vat_rate()
    |> cast(attrs, [:minimum_spend_input], empty_values: [])
    |> put_minimum_spend()
  end

  @doc """
  The offer's default VAT rate as the exact `Decimal` fraction C3 consumes
  (`WeddingPlanner.Offers.VatRate.to_decimal/1`), or `nil` for an inclusive offer (or one
  with no rate set).
  """
  @spec vat_rate(t()) :: Decimal.t() | nil
  def vat_rate(%__MODULE__{vat_rate_bp: nil}), do: nil
  def vat_rate(%__MODULE__{vat_rate_bp: bp}), do: VatRate.to_decimal(bp)

  @doc """
  Sets or clears `invoicing_complete` (`BIL-05`) — only
  `WeddingPlanner.Invoices.set_invoicing_complete/3` uses this; it refuses unless the
  offer is confirmed (see that function's moduledoc, `DR-58`).
  """
  @spec invoicing_complete_changeset(t(), boolean()) :: Ecto.Changeset.t()
  def invoicing_complete_changeset(%__MODULE__{} = offer, complete) when is_boolean(complete) do
    change(offer, invoicing_complete: complete)
  end

  @doc """
  Confirms or un-confirms `offer` in **one** `UPDATE` (`CST-40`, `CST-42`, `DR-62`) — only
  `WeddingPlanner.Offers.confirm_offer/2` / `unconfirm_offer/2` use this:

    * `true` → `status: :confirmed` and `planning_pick: false` (a confirmed offer is never
      the planning pick — the `offers_planning_pick_requires_open_status` CHECK, `DR-66`);
    * `false` → `status: :shortlisted` (`CST-42`, whatever the status was before) and
      `invoicing_complete: false` (the `offers_invoicing_complete_requires_confirmed`
      CHECK, `DR-58`: both columns must change in the same statement).
  """
  @spec confirmation_changeset(t(), boolean()) :: Ecto.Changeset.t()
  def confirmation_changeset(%__MODULE__{} = offer, true) do
    change(offer, status: :confirmed, planning_pick: false)
  end

  def confirmation_changeset(%__MODULE__{} = offer, false) do
    change(offer, status: :shortlisted, invoicing_complete: false)
  end

  @doc """
  Sets or clears `planning_pick` (`CST-44`, `DR-66`) — only `WeddingPlanner.Offers`'
  planning-pick functions use this; they check the rules (no confirmed or rejected offer,
  no confirmed offer in the category, one pick per category) first.
  """
  @spec planning_pick_changeset(t(), boolean()) :: Ecto.Changeset.t()
  def planning_pick_changeset(%__MODULE__{} = offer, pick) when is_boolean(pick) do
    change(offer, planning_pick: pick)
  end

  defp trim(value) when is_binary(value), do: String.trim(value)
  defp trim(value), do: value

  defp validate_url(changeset) do
    case get_change(changeset, :url) do
      nil ->
        changeset

      _raw ->
        changeset
        |> update_change(:url, &trim/1)
        |> validate_length(:url, max: @url_max)
        |> validate_change(:url, fn :url, url ->
          if http_url?(url), do: [], else: [url: "must be an http:// or https:// address"]
        end)
    end
  end

  # `DR-29`: http/https only, with a non-empty host — see `Reference.http_url?/1`, which
  # this mirrors exactly.
  defp http_url?(url) do
    case URI.new(url) do
      {:ok, %URI{scheme: scheme, host: host}}
      when scheme in ["http", "https"] and is_binary(host) and host != "" ->
        true

      _ ->
        false
    end
  end

  defp reject_confirmed_transition(changeset, %__MODULE__{status: old_status}) do
    new_status = get_field(changeset, :status)

    if new_status != old_status and (new_status == :confirmed or old_status == :confirmed) do
      add_error(changeset, :status, @confirmed_message)
    else
      changeset
    end
  end

  defp put_vat_rate(changeset) do
    case get_field(changeset, :vat_basis) do
      :inclusive -> clear_vat_rate(changeset)
      :exclusive -> apply_vat_rate_input(changeset)
    end
  end

  defp clear_vat_rate(changeset) do
    if get_field(changeset, :vat_rate_bp) != nil do
      put_change(changeset, :vat_rate_bp, nil)
    else
      changeset
    end
  end

  defp apply_vat_rate_input(changeset) do
    changeset =
      case get_change(changeset, :vat_rate_input) do
        nil ->
          changeset

        "" ->
          add_error(changeset, :vat_rate_input, "can't be blank")

        raw ->
          case VatRate.parse(raw) do
            {:ok, bp} -> put_change(changeset, :vat_rate_bp, bp)
            {:error, message} -> add_error(changeset, :vat_rate_input, message)
          end
      end

    if changeset.valid? and get_field(changeset, :vat_rate_bp) == nil do
      add_error(changeset, :vat_rate_input, "can't be blank")
    else
      changeset
    end
  end

  # Copied from `WeddingPlanner.Categories.Category.put_target/1` — see that module's
  # moduledoc for why `empty_values: []` (cast above) is what lets an explicit blank
  # string clear the amount while an omitted key leaves it alone.
  defp put_minimum_spend(changeset) do
    case get_change(changeset, :minimum_spend_input) do
      nil ->
        changeset

      "" ->
        put_change(changeset, :minimum_spend, nil)

      raw when is_binary(raw) ->
        case WeddingPlanner.Money.parse(raw) do
          {:ok, money} -> put_change(changeset, :minimum_spend, money)
          {:error, message} -> add_error(changeset, :minimum_spend_input, message)
        end
    end
  end
end
