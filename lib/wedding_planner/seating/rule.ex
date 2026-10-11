defmodule WeddingPlanner.Seating.Rule do
  @moduledoc """
  A seating rule (`docs/modules/seating.md` SEAT-30, SEAT-31): two sides, a relation and
  an optional reason.

  ## Sides

  A side is a `t:side/0`: `{:person, id}`, `{:circle, id}` or `:couple` — the couple is
  the users as a whole, never a reference to either user (`docs/03-domain-model.md`).
  It is stored as a kind plus at most one id (`a_kind`/`a_person_id`/`a_circle_id`, the
  same for `b`); `side_a/1`/`side_b/1` read it back.

  A rule is symmetric (SEAT-30), so the changeset stores the two sides in a **canonical
  order** (`side_key/1` ascending) whichever way round they were entered, and writes
  `pair_key` from them. The unique index on `pair_key` is "at most one rule per
  unordered pair".

  ## The form

  `changeset/2` casts the two virtual fields `subject` and `object`, each a
  `side_key/1` string (`"person:3"`, `"circle:2"`, `"couple"`) as a `<select>` submits
  it, plus `relation` and `reason`. Whether a referenced person or circle exists is
  checked by `WeddingPlanner.Seating`, not here, for the reason
  `WeddingPlanner.Guests`'s moduledoc gives (the SQLite adapter cannot name a violated
  foreign key).
  """
  use Ecto.Schema

  import Ecto.Changeset

  alias WeddingPlanner.Guests.Person
  alias WeddingPlanner.Seating.Circle

  @type relation :: :always_with | :seat_with | :keep_apart | :never_with
  @type side :: {:person, term()} | {:circle, term()} | :couple
  @type t :: %__MODULE__{}

  @relations [:always_with, :seat_with, :keep_apart, :never_with]
  @kinds [:person, :circle, :couple]

  schema "seating_rules" do
    field :a_kind, Ecto.Enum, values: @kinds
    belongs_to :a_person, Person
    belongs_to :a_circle, Circle
    field :b_kind, Ecto.Enum, values: @kinds
    belongs_to :b_person, Person
    belongs_to :b_circle, Circle

    field :relation, Ecto.Enum, values: @relations
    field :reason, :string
    field :pair_key, :string

    field :subject, :string, virtual: true
    field :object, :string, virtual: true

    timestamps(type: :utc_datetime)
  end

  @doc "The SEAT-31 relations, from strongest pull to strongest push."
  @spec relations() :: [relation()]
  def relations, do: @relations

  @doc "Whether `relation` is a hard constraint (SEAT-31)."
  @spec hard?(relation()) :: boolean()
  def hard?(relation), do: relation in [:always_with, :never_with]

  @doc "The UI label of a relation (SEAT-31)."
  @spec relation_label(relation()) :: String.t()
  def relation_label(:always_with), do: "always with"
  def relation_label(:seat_with), do: "seat with"
  def relation_label(:keep_apart), do: "keep apart"
  def relation_label(:never_with), do: "never with"

  @doc "The rule's first side, in canonical order."
  @spec side_a(t()) :: side()
  def side_a(%__MODULE__{a_kind: kind, a_person_id: person_id, a_circle_id: circle_id}),
    do: to_side(kind, person_id, circle_id)

  @doc "The rule's second side, in canonical order."
  @spec side_b(t()) :: side()
  def side_b(%__MODULE__{b_kind: kind, b_person_id: person_id, b_circle_id: circle_id}),
    do: to_side(kind, person_id, circle_id)

  @doc "Whether `side` is one of the rule's two sides."
  @spec mentions?(t(), side()) :: boolean()
  def mentions?(%__MODULE__{} = rule, side), do: side in [side_a(rule), side_b(rule)]

  @doc "The string form of a side, as a `<select>` submits it and `pair_key` joins it."
  @spec side_key(side()) :: String.t()
  def side_key(:couple), do: "couple"
  def side_key({:person, id}), do: "person:#{id}"
  def side_key({:circle, id}), do: "circle:#{id}"

  @doc "Parses `side_key/1`'s output back into a side; `:error` for anything else."
  @spec parse_side(term()) :: {:ok, side()} | :error
  def parse_side("couple"), do: {:ok, :couple}

  def parse_side("person:" <> id), do: parse_id(:person, id)
  def parse_side("circle:" <> id), do: parse_id(:circle, id)
  def parse_side(_other), do: :error

  defp parse_id(kind, id) do
    case Integer.parse(id) do
      {int, ""} when int > 0 -> {:ok, {kind, int}}
      _ -> :error
    end
  end

  @doc """
  Rule changeset: `subject`, `object` (side keys), `relation`, `reason` (trimmed, blank
  becomes `nil`). The sides must parse and differ (SEAT-30); they are stored in canonical
  order with their `pair_key`.
  """
  @spec changeset(t(), map()) :: Ecto.Changeset.t()
  def changeset(rule, attrs) do
    rule
    |> cast(attrs, [:subject, :object, :relation, :reason])
    |> update_change(:reason, &normalize_reason/1)
    |> validate_required([:subject, :object, :relation])
    |> validate_length(:reason, max: 200)
    |> put_sides()
    |> unique_constraint(:pair_key,
      error_key: :object,
      message: "there is already a rule between these two — edit that one instead"
    )
  end

  @doc "The form fields of an existing rule: its sides as `subject`/`object` keys."
  @spec with_form_fields(t()) :: t()
  def with_form_fields(%__MODULE__{id: nil} = rule), do: rule

  def with_form_fields(%__MODULE__{} = rule),
    do: %{rule | subject: side_key(side_a(rule)), object: side_key(side_b(rule))}

  defp put_sides(changeset) do
    with subject when is_binary(subject) <- get_field(changeset, :subject),
         object when is_binary(object) <- get_field(changeset, :object),
         {:subject, {:ok, a}} <- {:subject, parse_side(subject)},
         {:object, {:ok, b}} <- {:object, parse_side(object)} do
      if a == b do
        add_error(changeset, :object, "must be different from the first side")
      else
        [first, second] = Enum.sort_by([a, b], &side_key/1)

        changeset
        |> put_side(:a, first)
        |> put_side(:b, second)
        |> put_change(:pair_key, side_key(first) <> "|" <> side_key(second))
      end
    else
      {field, :error} -> add_error(changeset, field, "is not a person, circle or the couple")
      _missing -> changeset
    end
  end

  defp put_side(changeset, prefix, side) do
    {kind, person_id, circle_id} =
      case side do
        :couple -> {:couple, nil, nil}
        {:person, id} -> {:person, id, nil}
        {:circle, id} -> {:circle, nil, id}
      end

    changeset
    |> put_change(:"#{prefix}_kind", kind)
    |> put_change(:"#{prefix}_person_id", person_id)
    |> put_change(:"#{prefix}_circle_id", circle_id)
  end

  defp to_side(:couple, nil, nil), do: :couple
  defp to_side(:person, id, nil), do: {:person, id}
  defp to_side(:circle, nil, id), do: {:circle, id}

  defp normalize_reason(nil), do: nil

  defp normalize_reason(reason) do
    case String.trim(reason) do
      "" -> nil
      trimmed -> trimmed
    end
  end
end
