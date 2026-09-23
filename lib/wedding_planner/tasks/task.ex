defmodule WeddingPlanner.Tasks.Task do
  @moduledoc """
  A todo item (`docs/modules/tasks-and-timeline.md` TSK-01 through TSK-04).

  ## Owner (`TSK-01`, `D-28`)

  `owner_id` plus `owner_shared` together encode three states — a specific user, both
  (`owner_shared: true`), or nobody (`owner_id: nil`, `owner_shared: false`) — never a
  four-value enum, so a third user (AUTH-05) needs no schema change. The DB enforces
  "shared implies no owner id" via a CHECK constraint (see the migration); the changeset
  enforces the same thing so the error surfaces before it ever reaches SQLite.

  Whether a given `owner_id` is *allowed* (DR-22: only a user with at least one passkey)
  is **not** checked here — that requires a query, so it lives in
  `WeddingPlanner.Tasks.create_task/2` / `update_task/3` via
  `WeddingPlanner.Accounts.Users.assignable?/1`. This changeset only enforces the shape.

  ## Deadline (`TSK-02`, `TSK-03`)

  `deadline_kind` picks the shape; the other five `deadline_*` fields are only
  meaningful for the kind that owns them, and the changeset force-clears every field
  outside the chosen kind — so switching from `:relative` back to `:fixed`, say, never
  leaves a stale `deadline_amount` sitting in the row. `deadline_unit` is stored exactly
  as chosen (days or weeks), never normalised (Q16, DR-26).

  Resolving a relative deadline to a calendar date is `WeddingPlanner.Tasks.Deadline`'s
  job, not this module's — nothing here ever computes or stores a resolved date.

  ## Link (`TSK-01`, Q17/DR-26)

  `link_event_id` is the first of what will eventually be several nullable
  "link to X" foreign keys (task 32 adds `link_category_id`) — polymorphic in the API,
  enforced by the database (one FK per target type, at most one set). `@link_fields`
  is the extension point future link columns join.
  """
  use Ecto.Schema

  import Ecto.Changeset

  alias WeddingPlanner.Accounts.User
  alias WeddingPlanner.Events.Event

  @type t :: %__MODULE__{}

  @statuses [:to_do, :in_progress, :done]
  @deadline_kinds [:none, :fixed, :relative]
  @deadline_units [:days, :weeks]
  @deadline_directions [:before, :after]

  @link_fields [:link_event_id]

  schema "tasks" do
    field :title, :string
    field :notes, :string
    field :status, Ecto.Enum, values: @statuses, default: :to_do

    field :owner_shared, :boolean, default: false

    field :deadline_kind, Ecto.Enum, values: @deadline_kinds, default: :none
    field :deadline_date, :date
    field :deadline_amount, :integer
    field :deadline_unit, Ecto.Enum, values: @deadline_units
    field :deadline_direction, Ecto.Enum, values: @deadline_directions

    belongs_to :owner, User
    belongs_to :deadline_event, Event
    belongs_to :link_event, Event

    timestamps(type: :utc_datetime)
  end

  @doc "The deadline-related fields the changeset clears/validates together as one aspect."
  def deadline_fields,
    do: [
      :deadline_kind,
      :deadline_date,
      :deadline_amount,
      :deadline_unit,
      :deadline_direction,
      :deadline_event_id
    ]

  @doc "The link-related fields — see the moduledoc's \"Link\" section."
  def link_fields, do: @link_fields

  @doc """
  Changeset for creating/editing a task. Validates the shape described in the moduledoc:

    * `title` required, trimmed, 1–200 characters
    * owner is exactly one of {a user id, shared, nobody} (`D-28`) — does **not** check
      whether that user is *allowed* as an owner (DR-22); see the moduledoc
    * deadline fields are validated per `deadline_kind`, and switching kind clears every
      field belonging to a different kind
    * at most one link field is set
  """
  @spec changeset(t(), map()) :: Ecto.Changeset.t()
  def changeset(task, attrs) do
    task
    |> cast(attrs, [
      :title,
      :notes,
      :status,
      :owner_id,
      :owner_shared,
      :deadline_kind,
      :deadline_date,
      :deadline_amount,
      :deadline_unit,
      :deadline_direction,
      :deadline_event_id,
      :link_event_id
    ])
    |> update_change(:title, &trim/1)
    |> update_change(:notes, &trim_nilify/1)
    |> validate_required([:title])
    |> validate_length(:title, min: 1, max: 200)
    |> validate_owner()
    |> validate_deadline()
    |> validate_link()
  end

  defp trim(value) when is_binary(value), do: String.trim(value)
  defp trim(value), do: value

  defp trim_nilify(value) when is_binary(value) do
    case String.trim(value) do
      "" -> nil
      trimmed -> trimmed
    end
  end

  defp trim_nilify(value), do: value

  defp validate_owner(changeset) do
    owner_id = get_field(changeset, :owner_id)
    shared? = get_field(changeset, :owner_shared)

    if owner_id && shared? do
      add_error(changeset, :owner_id, "can't be set while the task is shared with both")
    else
      changeset
    end
  end

  defp validate_deadline(changeset) do
    case get_field(changeset, :deadline_kind) do
      :none ->
        clear_fields(changeset, deadline_fields())

      :fixed ->
        changeset
        |> clear_fields([
          :deadline_amount,
          :deadline_unit,
          :deadline_direction,
          :deadline_event_id
        ])
        |> validate_required([:deadline_date])

      :relative ->
        changeset
        |> clear_fields([:deadline_date])
        |> validate_required([
          :deadline_amount,
          :deadline_unit,
          :deadline_direction,
          :deadline_event_id
        ])
        |> validate_number(:deadline_amount, greater_than_or_equal_to: 0)

      nil ->
        changeset
    end
  end

  defp validate_link(changeset) do
    set_count =
      @link_fields
      |> Enum.map(&get_field(changeset, &1))
      |> Enum.count(&(!is_nil(&1)))

    if set_count > 1 do
      Enum.reduce(@link_fields, changeset, fn field, changeset ->
        add_error(changeset, field, "at most one link may be set")
      end)
    else
      changeset
    end
  end

  # Force-clears every field in `fields` to `nil`, overriding whatever attrs tried to
  # set — this is what makes "switching kind clears the other kind's fields" hold
  # unconditionally, not just when the caller remembers to omit them.
  defp clear_fields(changeset, fields) do
    Enum.reduce(fields, changeset, fn field, changeset ->
      if field == :deadline_kind, do: changeset, else: put_change(changeset, field, nil)
    end)
  end
end
