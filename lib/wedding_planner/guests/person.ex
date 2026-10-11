defmodule WeddingPlanner.Guests.Person do
  @moduledoc """
  A guest-list person (`docs/modules/guests-and-events.md` `PER-01`, `PER-02`,
  `PER-10` through `PER-16`, `docs/03-domain-model.md` Person; `D-29`, `DR-32`).

  ## Name (`PER-02`, `D-29`)

  `first_name` and `last_name` are both optional, plain-string fields, never one
  free-text field — the list sorts by last name (`PER-05`) and CSV exports the parts
  separately. `changeset/2` trims each and turns a blank string into `nil`; every person
  except an unnamed +1 MUST have at least one of the two. `display_name/1` derives the
  single rendered name from whichever parts exist, or, for an unnamed +1, from its host's.

  ## Fixed enums

  `age_category`, `want_tier` and `certainty` store exactly the atoms
  `WeddingPlanner.Valuation.Preset` already fixes (task 23), which the headcount engine
  reads. `changeset/2`'s defaults (`DR-26` Q6) are *adult* / *yes* / *likely* — set as
  the schema's own field defaults, so they apply the moment a bare `%Person{}` is built
  (quick-add, paste) and are simply left alone by `update_person/3`, which only ever
  casts fields actually present in its attrs.

  ## Group (`PER-03`)

  `group_id` is optional and cast, but not required, for a non-+1. This changeset
  declares `foreign_key_constraint/2` on it as a backstop, but the actual "does this
  group exist?" check lives in `WeddingPlanner.Guests.change_person/2` — see that
  module's moduledoc for why: this project's SQLite adapter cannot turn the constraint
  declaration below into a real changeset error. "At most one group" falls out of the FK
  being singular, not an extra rule here. A +1 has **no group of its own** (`DR-32`): the
  +1 changeset never casts `group_id`.

  ## +1s (`PER-10` through `PER-16`, `DR-32`)

  `host_id` (self `belongs_to :host`) makes a person a +1 of another person; `plus_ones`
  is the reverse `has_many`. Whether a given struct *is* a +1 is a data question, not an
  attrs question — `plus_one?/1` looks at `host_id`, which `changeset/2` never casts (it
  is set once, programmatically, by `WeddingPlanner.Guests.add_plus_one/3`, per
  AGENTS.md's "fields set programmatically are put on the struct, not cast").
  `changeset/2` branches on `plus_one?/1` of the struct it is given:

    * a non-+1 (`host_id` nil): unchanged from before this task — casts the ordinary
      `PER-02` fields, requires a name.
    * a +1 (`host_id` set): delegates to `plus_one_changeset/2` — names are optional,
      `plus_one_status` is required, age/notes/names/`plus_one_status` are cast, and
      `want_tier`, `certainty` or `group_id` showing up in `attrs` at all (regardless of
      value) is a changeset error "is inherited from the host" on that field, because
      those three are **not editable on a +1** (`PER-15`, `DR-32`) — `want_tier` and
      `certainty` are written once, from the host, at creation
      (`WeddingPlanner.Guests.add_plus_one/3`) and from then on are only ever *read*
      through the pure `WeddingPlanner.Guests.PlusOne` helper, never through these
      columns directly.

  `name_known?/1` is always `true` for a non-+1 (PER-02 already guarantees a name) and,
  for a +1, `true` iff it has a first or a last name — **not stored** (`DR-32`): storage
  layout is not binding (`docs/03-domain-model.md`), and a persisted flag could drift
  from the name fields it claims to describe.
  """
  use Ecto.Schema

  import Ecto.Changeset

  alias WeddingPlanner.Accounts.User
  alias WeddingPlanner.Guests.Group

  @type age_category :: :adult | :child
  @type want_tier :: :yes | :maybe | :no | :obligated
  @type certainty :: :certain | :likely | :uncertain
  @type plus_one_status :: :possible | :confirmed
  @type t :: %__MODULE__{}

  @typedoc "A parsed name pair, e.g. `WeddingPlanner.Guests.PasteParser.parse/1`'s `:ok` results."
  @type name_map :: %{first_name: String.t() | nil, last_name: String.t() | nil}

  @age_categories [:adult, :child]
  @want_tiers [:yes, :maybe, :no, :obligated]
  @certainties [:certain, :likely, :uncertain]
  @plus_one_statuses [:possible, :confirmed]

  @fields [
    :first_name,
    :last_name,
    :age_category,
    :want_tier,
    :certainty,
    :notes,
    :group_id,
    :fine_anywhere
  ]
  @plus_one_fields [
    :first_name,
    :last_name,
    :age_category,
    :notes,
    :plus_one_status,
    :fine_anywhere
  ]
  @inherited_fields [:want_tier, :certainty, :group_id]

  schema "persons" do
    field :first_name, :string
    field :last_name, :string
    field :age_category, Ecto.Enum, values: @age_categories, default: :adult
    field :want_tier, Ecto.Enum, values: @want_tiers, default: :yes
    field :certainty, Ecto.Enum, values: @certainties, default: :likely
    field :notes, :string
    field :plus_one_status, Ecto.Enum, values: @plus_one_statuses
    # SEAT-35: content at any table; a +1 has its own (it is about the person, not the host).
    field :fine_anywhere, :boolean, default: false

    belongs_to :group, Group
    belongs_to :host, __MODULE__
    # PER-20: never cast; `WeddingPlanner.Guests.set_witness/3` is the only writer.
    belongs_to :witness_of, User
    has_many :plus_ones, __MODULE__, foreign_key: :host_id

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

  @doc "The fixed `plus_one_status` atoms, in the order `docs/` names them (`PER-12`)."
  @spec plus_one_statuses() :: [plus_one_status()]
  def plus_one_statuses, do: @plus_one_statuses

  @doc "`true` iff `person` is a +1 of another person (`PER-10`) — i.e. `host_id` is set."
  @spec plus_one?(t()) :: boolean()
  def plus_one?(%__MODULE__{host_id: host_id}), do: not is_nil(host_id)

  @doc "`true` iff `person` is a witness of one of the two users (`PER-20`)."
  @spec witness?(t()) :: boolean()
  def witness?(%__MODULE__{witness_of_id: witness_of_id}), do: not is_nil(witness_of_id)

  @doc """
  `true` iff `person`'s name is known (`PER-11`): always `true` for a non-+1 (`PER-02`
  already guarantees a name); for a +1, `true` iff it has a first or a last name.
  Deliberately not a stored column — see the moduledoc.
  """
  @spec name_known?(t()) :: boolean()
  def name_known?(%__MODULE__{host_id: nil}), do: true
  def name_known?(%__MODULE__{first_name: nil, last_name: nil}), do: false
  def name_known?(%__MODULE__{}), do: true

  @doc """
  Person changeset. Branches on `plus_one?/1` of `person` (see the moduledoc's "+1s"
  section):

    * a non-+1 (`PER-02`) — trims `first_name`/`last_name` and turns a blank string
      into `nil`; requires at least one of the two, attaching the error to **both**
      fields' form keys so a form can show it next to either one; casts the three fixed
      enums (`Ecto.Enum` rejects anything outside them); declares a `group_id` foreign
      key constraint as a backstop (see the moduledoc's "Group" section for why the real
      existence check lives in `WeddingPlanner.Guests.change_person/2` instead).
    * a +1 (`PER-10` through `PER-16`) — delegates to `plus_one_changeset/2`.
  """
  @spec changeset(t(), map()) :: Ecto.Changeset.t()
  def changeset(person, attrs) do
    if plus_one?(person) do
      plus_one_changeset(person, attrs)
    else
      person
      |> cast(attrs, @fields)
      |> update_change(:first_name, &normalize/1)
      |> update_change(:last_name, &normalize/1)
      |> validate_required([:age_category, :want_tier, :certainty])
      |> validate_name_present()
      |> reject_witness_overrides(person)
      |> foreign_key_constraint(:group_id)
    end
  end

  @doc """
  Changeset for a +1 (`host_id` already set on `person`, never cast here — see the
  moduledoc). Names are optional (`PER-11`); `plus_one_status` is required (`PER-12`);
  age, notes, names and `plus_one_status` are cast. `want_tier`, `certainty` or
  `group_id` present anywhere in `attrs` — string or atom key, whatever the value — is
  refused with "is inherited from the host" on that field (`PER-15`, `DR-32`): those
  three are not editable on a +1, so there is nothing for `cast/3` to reject on its own
  (they simply are not in the +1 field list); this validation is what turns "not
  editable" into an actual changeset error instead of a silently ignored key.
  """
  @spec plus_one_changeset(t(), map()) :: Ecto.Changeset.t()
  def plus_one_changeset(person, attrs) do
    person
    |> cast(attrs, @plus_one_fields)
    |> update_change(:first_name, &normalize/1)
    |> update_change(:last_name, &normalize/1)
    |> validate_required([:age_category, :plus_one_status])
    |> reject_inherited_fields(attrs)
    |> foreign_key_constraint(:host_id)
  end

  @doc """
  Derived display name (`PER-02`, `PER-11`).

  A non-+1 or a named +1: first and last, whichever exist, space-joined. An unnamed +1:
  `"+1 of " <> display_name(host)` — this needs `:host` preloaded and raises
  `ArgumentError` if it is not, rather than ever rendering an empty or wrong name.
  """
  @spec display_name(t()) :: String.t()
  def display_name(%__MODULE__{} = person) do
    if plus_one?(person) and not name_known?(person) do
      unnamed_plus_one_display_name(person)
    else
      own_name(person)
    end
  end

  defp own_name(%__MODULE__{first_name: nil, last_name: nil}), do: ""
  defp own_name(%__MODULE__{first_name: first, last_name: nil}), do: first
  defp own_name(%__MODULE__{first_name: nil, last_name: last}), do: last
  defp own_name(%__MODULE__{first_name: first, last_name: last}), do: "#{first} #{last}"

  defp unnamed_plus_one_display_name(%__MODULE__{host: %__MODULE__{} = host}) do
    "+1 of " <> display_name(host)
  end

  defp unnamed_plus_one_display_name(%__MODULE__{id: id}) do
    raise ArgumentError,
          "Person.display_name/1 needs :host preloaded for an unnamed +1 (person id=#{inspect(id)}); " <>
            "call Repo.preload(person, :host) first"
  end

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

  # PER-22: a witness is always obligated and certain — neither is editable.
  defp reject_witness_overrides(changeset, person) do
    if witness?(person) do
      Enum.reduce([want_tier: :obligated, certainty: :certain], changeset, fn {field, forced},
                                                                              acc ->
        if get_field(acc, field) == forced,
          do: acc,
          else: add_error(acc, field, "is fixed while the person is a witness")
      end)
    else
      changeset
    end
  end

  defp reject_inherited_fields(changeset, attrs) do
    Enum.reduce(@inherited_fields, changeset, fn field, acc ->
      if attrs_has_key?(attrs, field) do
        add_error(acc, field, "is inherited from the host")
      else
        acc
      end
    end)
  end

  defp attrs_has_key?(attrs, field) do
    Map.has_key?(attrs, field) or Map.has_key?(attrs, Atom.to_string(field))
  end
end
