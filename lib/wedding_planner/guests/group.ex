defmodule WeddingPlanner.Guests.Group do
  @moduledoc """
  A guest-list group (`docs/03-domain-model.md` Group; `PER-03`, `PER-07`): a name plus
  an optional free-text type label ("household", "circle"... — `DR-26` Q10).

  Purely organisational: a group carries no data of its own that overrides a person's
  (`PER-04`). Membership is the single `group_id` foreign key on `Person` — `PER-03`'s
  "at most one group" is enforced by that FK being singular, not by anything here.
  """
  use Ecto.Schema

  import Ecto.Changeset

  alias WeddingPlanner.Guests.Person

  @type t :: %__MODULE__{}

  schema "groups" do
    field :name, :string
    field :type_label, :string

    has_many :persons, Person

    timestamps(type: :utc_datetime)
  end

  @doc """
  Group changeset: `name` is required, `type_label` is free text and optional
  (`DR-26` Q10). Blank strings are normalised to `nil`.
  """
  @spec changeset(t(), map()) :: Ecto.Changeset.t()
  def changeset(group, attrs) do
    group
    |> cast(attrs, [:name, :type_label])
    |> update_change(:name, &normalize/1)
    |> update_change(:type_label, &normalize/1)
    |> validate_required([:name])
    |> validate_length(:name, min: 1, max: 200)
  end

  defp normalize(nil), do: nil

  defp normalize(value) do
    case String.trim(value) do
      "" -> nil
      trimmed -> trimmed
    end
  end
end
