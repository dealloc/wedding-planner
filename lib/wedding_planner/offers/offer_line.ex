defmodule WeddingPlanner.Offers.OfferLine do
  @moduledoc """
  One priced element of an offer (`docs/modules/offers-and-comparison.md` `CST-20` through
  `CST-23`, `CST-30` through `CST-33`, `CST-36`; `docs/03-domain-model.md`'s Offer line;
  `DR-41`). Nothing here computes an amount: these fields are the stored **inputs** of the
  C3 cost engine, and the normative offer examples O1–O6 must round-trip through them
  exactly.

  `offer_id` is set **programmatically** from an already-loaded offer
  (`WeddingPlanner.Offers.create_line/3`) and never cast. `enabled` is never cast either:
  `WeddingPlanner.Offers.set_line_enabled/3` is the only way to turn it on.

  ## Shape (`DR-41`)

    * **Exactly one** of `service_id` / `label` (`CST-20`). A blank label is unset.
    * An optional `variation` name, on service lines only (`CST-27`). A blank one is unset.
    * **Ad hoc** lines (no service) are only `:mandatory` or `:optional` (`CST-22`).
    * **Priced states** (`:mandatory`, `:optional`) require `basis` and `amount`.
    * **Unpriced states** (`:included`, `:not_offered`, `:unknown`) carry no pricing
      field at all. The changeset **clears** `basis`, `amount`, `event_id`,
      `included_quantity`, `minimum_charge` and `vat_rate_bp` instead of refusing, and
      does not even parse the `*_input` fields — the form must not fight the state select.
    * `basis: :flat` clears `event_id` and `included_quantity` (`CST-31`, `CST-32`).
    * A **per-person** basis requires `event_id` on any write that touches `basis` or
      `event_id` — creation always does (`CST-31`). An existing line whose event was
      deleted (`WeddingPlanner.Offers.detach_event/2`, `XC-41`) is *invalid*
      (`invalid?/1`): editing its other fields leaves it invalid; setting an event or
      switching to flat repairs it — never automatically (`XC-42`).
    * `enabled` is forced back to `false` by any change that makes the line no longer an
      optional ad hoc line (`CST-22`).

  Normalisation (clearing) runs before validation. The existence checks — the service
  belongs to the offer's category, the event exists, the line rate is only set while the
  offer is VAT exclusive — need queries and live in `WeddingPlanner.Offers.change_line/2`.
  Every structural rule is also a named database CHECK (see the migration).

  ## Inputs (`DR-18`, `DR-23`, `DR-40`)

  `amount_input` and `minimum_charge_input` are parsed with `WeddingPlanner.Money.parse/2`
  only; `vat_rate_input` with `WeddingPlanner.Offers.VatRate.parse/1` only. An explicit
  blank clears the field, an omitted key leaves it untouched — the same contract as
  `WeddingPlanner.Offers.Offer`'s `minimum_spend_input`.

  Code (seeds, fixtures, the normative-input tests) may instead pass already-typed
  values: `amount`/`minimum_charge` as a `%Money{}` in EUR, `vat_rate_bp` as an integer
  in `0..10000`. Anything else under those keys — notably a string, which `Money.new/2`
  would misread under nl-BE (`DR-18`) — is refused, never converted. A typed value and
  an `*_input` for the same field should not be combined; if they are, the input wins.

  Amounts are in the offer's own VAT basis (`CST-36`) and are stored exactly as given —
  never grossed up, never rounded. Required-field errors are reported on the `*_input`
  field the form shows.
  """
  use Ecto.Schema

  import Ecto.Changeset

  alias WeddingPlanner.Categories.Service
  alias WeddingPlanner.Events.Event
  alias WeddingPlanner.Offers.Offer
  alias WeddingPlanner.Offers.VatRate

  @type t :: %__MODULE__{}

  @label_max 200
  @notes_max 2000
  @states [:included, :optional, :mandatory, :not_offered, :unknown]
  @priced_states [:mandatory, :optional]
  @bases [:flat, :per_adult, :per_child, :per_attendee]
  @per_person_bases [:per_adult, :per_child, :per_attendee]
  @pricing_fields [
    :basis,
    :amount,
    :event_id,
    :included_quantity,
    :minimum_charge,
    :vat_rate_bp
  ]

  schema "offer_lines" do
    belongs_to :offer, Offer
    belongs_to :service, Service
    belongs_to :event, Event

    field :label, :string
    field :variation, :string
    # CST-27: never cast; `WeddingPlanner.Offers.choose_variation/4` is the only writer.
    field :chosen, :boolean, default: false
    field :notes, :string
    field :state, Ecto.Enum, values: @states
    field :basis, Ecto.Enum, values: @bases
    field :amount, Money.Ecto.Map.Type
    field :amount_input, :string, virtual: true
    field :minimum_charge, Money.Ecto.Map.Type
    field :minimum_charge_input, :string, virtual: true
    field :included_quantity, :integer
    field :vat_rate_bp, :integer
    field :vat_rate_input, :string, virtual: true
    field :enabled, :boolean, default: false

    timestamps(type: :utc_datetime)
  end

  @doc "The five states of `CST-21`."
  @spec states() :: [atom()]
  def states, do: @states

  @doc "The four pricing bases of `CST-30`."
  @spec bases() :: [atom()]
  def bases, do: @bases

  @doc "Whether `state` carries a price (`:mandatory`, `:optional`) — `DR-41`."
  @spec priced_state?(atom()) :: boolean()
  def priced_state?(state), do: state in @priced_states

  @doc "Whether `basis` counts persons (`CST-31`) — every basis but `:flat` (and `nil`)."
  @spec per_person?(atom() | nil) :: boolean()
  def per_person?(basis), do: basis in @per_person_bases

  @doc """
  `XC-41`/`XC-42`, `DR-41`: a line is invalid when it is per-person and has no event — the
  only way to get there is deleting its event (`WeddingPlanner.Offers.detach_event/2`).
  Derived, never stored.
  """
  @spec invalid?(t()) :: boolean()
  def invalid?(%__MODULE__{basis: basis, event_id: event_id}),
    do: per_person?(basis) and is_nil(event_id)

  @doc """
  The line's own VAT override as the exact `Decimal` fraction C3 consumes
  (`VatRate.to_decimal/1`), or `nil` when it uses the offer's default. On a VAT-inclusive
  offer a retained value is ignored by C3 (`CST-36` step 5) — this function does not know
  the offer and does not decide that.
  """
  @spec vat_rate(t()) :: Decimal.t() | nil
  def vat_rate(%__MODULE__{vat_rate_bp: nil}), do: nil
  def vat_rate(%__MODULE__{vat_rate_bp: bp}), do: VatRate.to_decimal(bp)

  @doc """
  The structural changeset (see the moduledoc). Does **not** check that the service
  belongs to the offer's category, that the event exists, or that a line rate is allowed
  by the offer's basis — `WeddingPlanner.Offers.change_line/2` adds those.
  """
  @spec changeset(t(), map()) :: Ecto.Changeset.t()
  def changeset(line, attrs) do
    line
    |> cast(attrs, [
      :service_id,
      :label,
      :variation,
      :notes,
      :state,
      :basis,
      :event_id,
      :included_quantity
    ])
    |> update_change(:label, &trim_label/1)
    |> update_change(:variation, &trim_label/1)
    |> cast(attrs, [:amount_input, :minimum_charge_input, :vat_rate_input], empty_values: [])
    # -- normalisation ----------------------------------------------------------------
    |> normalise_pricing(attrs)
    |> reset_enabled()
    # -- validation -------------------------------------------------------------------
    |> validate_required([:state])
    |> validate_length(:label, max: @label_max)
    |> validate_length(:notes, max: @notes_max)
    |> validate_length(:variation, max: @label_max)
    |> validate_variation_on_service_line()
    |> validate_service_xor_label()
    |> validate_ad_hoc_state()
    |> validate_priced_fields()
    |> validate_event_for_per_person(line)
    |> validate_number(:included_quantity, greater_than_or_equal_to: 0)
  end

  @doc "Changeset setting `enabled` (`CST-22`) — only for an optional ad hoc line."
  @spec enabled_changeset(t(), boolean()) :: Ecto.Changeset.t()
  def enabled_changeset(%__MODULE__{} = line, enabled) when is_boolean(enabled) do
    change(line, enabled: enabled)
  end

  @doc "Whether `line` is an optional ad hoc line, the only kind with an on/off toggle (`CST-22`)."
  @spec optional_ad_hoc?(t()) :: boolean()
  def optional_ad_hoc?(%__MODULE__{service_id: nil, state: :optional}), do: true
  def optional_ad_hoc?(%__MODULE__{}), do: false

  # -- normalisation ------------------------------------------------------------------

  defp normalise_pricing(changeset, attrs) do
    if priced_state?(get_field(changeset, :state)) do
      changeset
      |> put_typed_money(attrs, :amount, :amount_input)
      |> put_typed_money(attrs, :minimum_charge, :minimum_charge_input)
      |> put_typed_vat_rate(attrs)
      |> put_money_input(:amount_input, :amount)
      |> put_money_input(:minimum_charge_input, :minimum_charge)
      |> put_vat_rate_input()
      |> clear_for_flat()
    else
      Enum.reduce(@pricing_fields, changeset, &clear_field(&2, &1))
    end
  end

  defp clear_for_flat(changeset) do
    if get_field(changeset, :basis) == :flat do
      changeset |> clear_field(:event_id) |> clear_field(:included_quantity)
    else
      changeset
    end
  end

  # `put_change/3` records nothing when the stored value is already nil, and drops a
  # pending change back to the stored nil — so clearing never logs a spurious change.
  defp clear_field(changeset, field), do: put_change(changeset, field, nil)

  defp put_money_input(changeset, input_field, field) do
    case get_change(changeset, input_field) do
      nil ->
        changeset

      raw when is_binary(raw) ->
        if String.trim(raw) == "" do
          put_change(changeset, field, nil)
        else
          case WeddingPlanner.Money.parse(raw) do
            {:ok, money} -> put_money(changeset, field, money)
            {:error, message} -> add_error(changeset, input_field, message)
          end
        end
    end
  end

  # The programmatic path (seeds, fixtures, the normative-input tests): an already-built
  # `%Money{}` in EUR (`NFR-15`) under `:amount`/`:minimum_charge`. Anything else under
  # those keys — above all a string, which `Money.new/2` would read under the nl-BE
  # locale (`DR-18`) — is refused, never converted.
  defp put_typed_money(changeset, attrs, field, input_field) do
    case fetch_attr(attrs, field) do
      :error -> changeset
      {:ok, nil} -> put_change(changeset, field, nil)
      {:ok, %Money{currency: :EUR} = money} -> put_money(changeset, field, money)
      {:ok, _other} -> add_error(changeset, input_field, "is invalid")
    end
  end

  # The programmatic path for a line rate: basis points (`VatRate`), never a float.
  defp put_typed_vat_rate(changeset, attrs) do
    case fetch_attr(attrs, :vat_rate_bp) do
      :error -> changeset
      {:ok, nil} -> put_change(changeset, :vat_rate_bp, nil)
      {:ok, bp} when is_integer(bp) and bp in 0..10_000 -> put_change(changeset, :vat_rate_bp, bp)
      {:ok, _other} -> add_error(changeset, :vat_rate_input, "is invalid")
    end
  end

  defp fetch_attr(attrs, key) do
    case Map.fetch(attrs, key) do
      {:ok, value} -> {:ok, value}
      :error -> Map.fetch(attrs, Atom.to_string(key))
    end
  end

  # Re-typing an equal amount ("85,00" over a stored € 85) is not a change: `put_change/3`
  # compares through `Money.Ecto.Map.Type.equal?/2`, so the stored value is kept as it is
  # and nothing is logged.
  defp put_money(changeset, field, %Money{} = money), do: put_change(changeset, field, money)

  defp put_vat_rate_input(changeset) do
    case get_change(changeset, :vat_rate_input) do
      nil ->
        changeset

      raw when is_binary(raw) ->
        if String.trim(raw) == "" do
          put_change(changeset, :vat_rate_bp, nil)
        else
          case VatRate.parse(raw) do
            {:ok, bp} -> put_change(changeset, :vat_rate_bp, bp)
            {:error, message} -> add_error(changeset, :vat_rate_input, message)
          end
        end
    end
  end

  defp reset_enabled(changeset) do
    optional_ad_hoc? =
      is_nil(get_field(changeset, :service_id)) and get_field(changeset, :state) == :optional

    if get_field(changeset, :enabled) and not optional_ad_hoc? do
      put_change(changeset, :enabled, false)
    else
      changeset
    end
  end

  # -- validation ---------------------------------------------------------------------

  defp trim_label(nil), do: nil
  defp trim_label(label), do: String.trim(label)

  # CST-27: only a service line can be a variation of its service.
  defp validate_variation_on_service_line(changeset) do
    if get_field(changeset, :variation) not in [nil, ""] and
         is_nil(get_field(changeset, :service_id)) do
      add_error(changeset, :variation, "only a service line can have a variation")
    else
      changeset
    end
  end

  defp validate_service_xor_label(changeset) do
    case {get_field(changeset, :service_id), get_field(changeset, :label)} do
      {nil, nil} ->
        add_error(changeset, :service_id, "choose a service, or enter a label for an ad hoc line")

      {_service_id, nil} ->
        changeset

      {nil, _label} ->
        changeset

      {_service_id, _label} ->
        add_error(changeset, :label, "a service line has no label of its own — clear one of them")
    end
  end

  defp validate_ad_hoc_state(changeset) do
    state = get_field(changeset, :state)

    if is_nil(get_field(changeset, :service_id)) and not is_nil(state) and
         not priced_state?(state) do
      add_error(changeset, :state, "an ad hoc line can only be mandatory or optional")
    else
      changeset
    end
  end

  defp validate_priced_fields(changeset) do
    if priced_state?(get_field(changeset, :state)) do
      changeset
      |> require_field(:basis, :basis)
      |> require_field(:amount, :amount_input)
    else
      changeset
    end
  end

  defp require_field(changeset, field, error_field) do
    if is_nil(get_field(changeset, field)) and not Keyword.has_key?(changeset.errors, error_field) do
      add_error(changeset, error_field, "can't be blank", validation: :required)
    else
      changeset
    end
  end

  # CST-31: only enforced on a write that touches `basis` or `event_id` (creation always
  # does) — so an invalid line (event deleted, XC-41) can still have its other fields
  # edited, and stays invalid until a user repairs it (XC-42).
  defp validate_event_for_per_person(changeset, %__MODULE__{} = line) do
    touches? =
      is_nil(line.id) or Map.has_key?(changeset.changes, :basis) or
        Map.has_key?(changeset.changes, :event_id)

    if touches? and per_person?(get_field(changeset, :basis)) and
         is_nil(get_field(changeset, :event_id)) do
      add_error(changeset, :event_id, "a per-person line needs an event", validation: :required)
    else
      changeset
    end
  end
end
