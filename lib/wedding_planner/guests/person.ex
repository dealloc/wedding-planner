defmodule WeddingPlanner.Guests.Person do
  @moduledoc """
  A guest-list person (`docs/modules/guests-and-events.md` `PER-01`, `PER-02`,
  `docs/03-domain-model.md` Person; `D-29`).

  ## Name (`PER-02`, `D-29`)

  `first_name` and `last_name` are both optional, plain-string fields, never one
  free-text field — the list sorts by last name (`PER-05`) and CSV exports the parts
  separately. `changeset/2` trims each and turns a blank string into `nil`; every person
  MUST have at least one of the two (this task has no +1s yet, so that rule applies to
  *every* person here — G2 relaxes it for an unnamed +1). `display_name/1` derives the
  single rendered name from whichever parts exist.

  ## Fixed enums

  `age_category`, `want_tier` and `certainty` store exactly the atoms
  `WeddingPlanner.Valuation.Preset` already fixes (task 23), which the headcount engine
  reads. `changeset/2`'s defaults (`DR-26` Q6) are *adult* / *yes* / *likely* — set as
  the schema's own field defaults, so they apply the moment a bare `%Person{}` is built
  (quick-add, paste) and are simply left alone by `update_person/3`, which only ever
  casts fields actually present in its attrs.

  ## Group (`PER-03`)

  `group_id` is optional and cast, but not required. This changeset declares
  `foreign_key_constraint/2` on it as a backstop, but the actual "does this group
  exist?" check lives in `WeddingPlanner.Guests.change_person/2` — see that module's
  moduledoc for why: this project's SQLite adapter cannot turn the constraint
  declaration below into a real changeset error. "At most one group" falls out of the FK
  being singular, not an extra rule here.
  """
  use Ecto.Schema

  import Ecto.Changeset

  alias WeddingPlanner.Guests.Group

  @type age_category :: :adult | :child
  @type want_tier :: :yes | :maybe | :no | :obligated
  @type certainty :: :certain | :likely | :uncertain
  @type t :: %__MODULE__{}

  @typedoc "A parsed name pair, e.g. `WeddingPlanner.Guests.PasteParser.parse/1`'s `:ok` results."
  @type name_map :: %{first_name: String.t() | nil, last_name: String.t() | nil}

  @age_categories [:adult, :child]
  @want_tiers [:yes, :maybe, :no, :obligated]
  @certainties [:certain, :likely, :uncertain]

  @fields [:first_name, :last_name, :age_category, :want_tier, :certainty, :notes, :group_id]

  schema "persons" do
    field :first_name, :string
    field :last_name, :string
    field :age_category, Ecto.Enum, values: @age_categories, default: :adult
    field :want_tier, Ecto.Enum, values: @want_tiers, default: :yes
    field :certainty, Ecto.Enum, values: @certainties, default: :likely
    field :notes, :string

    belongs_to :group, Group

    timestamps(type: :utc_datetime)
  end

  @doc "The fixed `age_category` atoms, in the order `docs/` names them."
  @spec age_categories() :: [age_category()]
  def age_categories, do: @age_categories

  @doc "The fixed `want_tier` atoms, in the order `docs/` names them."
  @spec want_tiers() :: [want_tier()]
  def want_tiers, do: @want_tiers

  @doc "The fixed `certainty` atoms, in the order `docs/` names them."
  @spec certainties() :: [certainty()]
  def certainties, do: @certainties

  @doc """
  Person changeset (`PER-02`). Trims `first_name`/`last_name` and turns a blank string
  into `nil`; requires at least one of the two, attaching the error to **both** fields'
  form keys so a form can show it next to either one; casts the three fixed enums
  (`Ecto.Enum` rejects anything outside them); declares a `group_id` foreign key
  constraint as a backstop (see the moduledoc's "Group" section for why the real
  existence check lives in `WeddingPlanner.Guests.change_person/2` instead).
  """
  @spec changeset(t(), map()) :: Ecto.Changeset.t()
  def changeset(person, attrs) do
    person
    |> cast(attrs, @fields)
    |> update_change(:first_name, &normalize/1)
    |> update_change(:last_name, &normalize/1)
    |> validate_required([:age_category, :want_tier, :certainty])
    |> validate_name_present()
    |> foreign_key_constraint(:group_id)
  end

  @doc "Derived display name (`PER-02`): first and last, whichever exist, space-joined."
  @spec display_name(t()) :: String.t()
  def display_name(%__MODULE__{first_name: nil, last_name: nil}), do: ""
  def display_name(%__MODULE__{first_name: first, last_name: nil}), do: first
  def display_name(%__MODULE__{first_name: nil, last_name: last}), do: last

  def display_name(%__MODULE__{first_name: first, last_name: last}),
    do: "#{first} #{last}"

  defp normalize(nil), do: nil

  defp normalize(value) do
    case String.trim(value) do
      "" -> nil
      trimmed -> trimmed
    end
  end

  defp validate_name_present(changeset) do
    if is_nil(get_field(changeset, :first_name)) and is_nil(get_field(changeset, :last_name)) do
      changeset
      |> add_error(:first_name, "must provide a first or last name")
      |> add_error(:last_name, "must provide a first or last name")
    else
      changeset
    end
  end
end
