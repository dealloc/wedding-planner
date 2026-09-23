defmodule WeddingPlanner.Categories.Service do
  @moduledoc """
  A service within a category (`docs/modules/offers-and-comparison.md` `CST-02`,
  `CST-03`; `docs/03-domain-model.md`'s Service entity): a name, a **wanted priority**
  and a manual sort order, scoped to its category. Services are created on the fly while
  entering offers (`CST-02`; `WeddingPlanner.Categories.create_service/3` is that entry
  point).

  ## Wanted priority (`CST-03`)

  One of `:not_wanted`, `:nice_to_have` or `:must_have` — the category-wide selection
  used to compare offers fairly. Defaults to `:nice_to_have` for a new service.

  ## Name uniqueness (`CST-04`, `DR-26` Q14)

  Two services in the same category may not share a name, compared case-insensitively
  and Unicode-aware (`String.downcase/1` — SQLite's own `lower()` only folds ASCII, so
  the `services` migration's matching unique index is a backstop, not the primary
  guard). A different category may reuse the same name freely. That check needs a
  query, so it is not in this changeset — see
  `WeddingPlanner.Categories.validate_name_unique_in_category/3`, applied by
  `WeddingPlanner.Categories.change_service/2`.

  `sort_order` is set programmatically by `WeddingPlanner.Categories` — appended after
  the current last service **in its category** on create, swapped between two
  neighbours *within the same category* by `WeddingPlanner.Categories.move_service/3` —
  and is deliberately absent from `changeset/2` so it can never be set through a form.
  `category_id` is likewise never castable here: it is set once, on the struct, before
  the changeset runs.
  """
  use Ecto.Schema

  import Ecto.Changeset

  alias WeddingPlanner.Categories.Category

  @type t :: %__MODULE__{}

  @wanted_priorities [:not_wanted, :nice_to_have, :must_have]

  @doc "The valid `wanted_priority` values, in the order shown to the user."
  @spec wanted_priorities() :: [atom()]
  def wanted_priorities, do: @wanted_priorities

  schema "services" do
    field :name, :string
    field :wanted_priority, Ecto.Enum, values: @wanted_priorities, default: :nice_to_have
    field :sort_order, :integer

    belongs_to :category, Category

    timestamps(type: :utc_datetime)
  end

  @doc """
  Changeset for the user-facing fields (`CST-03`, `CST-04`): `name` required, 1–200
  characters, trimmed; `wanted_priority` one of #{inspect(@wanted_priorities)}.
  `category_id` and `sort_order` are intentionally not castable here (see moduledoc).
  Does **not** enforce name uniqueness on its own — see
  `WeddingPlanner.Categories.change_service/2`, which layers that on top since it needs
  a query.
  """
  @spec changeset(t(), map()) :: Ecto.Changeset.t()
  def changeset(service, attrs) do
    service
    |> cast(attrs, [:name, :wanted_priority])
    |> update_change(:name, &trim/1)
    |> validate_required([:name, :wanted_priority])
    |> validate_length(:name, min: 1, max: 200)
  end

  @doc """
  Programmatic-only changeset for reordering
  (`WeddingPlanner.Categories.move_service/3`). Never driven directly by user input.
  """
  @spec sort_order_changeset(t(), integer()) :: Ecto.Changeset.t()
  def sort_order_changeset(service, sort_order) when is_integer(sort_order) do
    change(service, sort_order: sort_order)
  end

  defp trim(value) when is_binary(value), do: String.trim(value)
  defp trim(value), do: value
end
