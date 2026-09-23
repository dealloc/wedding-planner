defmodule WeddingPlanner.Categories.Category do
  @moduledoc """
  A cost category (`docs/modules/offers-and-comparison.md` `CST-01`, `CST-05`;
  `docs/03-domain-model.md`'s Category entity): a name, an optional **target** budget
  amount and a manual sort order. Categories are user-defined and may be as granular as
  the users like (`CST-05`).

  ## Target amount (`DR-23`, `DR-18`)

  `target_input` is a virtual field carrying whatever the user typed in the form (a raw
  nl-BE amount string, or the empty string to clear the target). `changeset/2` parses it
  via `WeddingPlanner.Money.parse/1` and, on success, sets the real `target` field from
  the resulting `%Money{}` — copied exactly from `WeddingPlanner.Settings`'
  `overall_budget_input` pattern: `cast(..., empty_values: [])` so an **explicit empty
  string clears** the target back to unset (`nil`) while an **omitted key leaves it
  untouched**. `target` itself only ever holds a `%Money{}` or `nil`, never user-typed
  text (`DR-18` — money is never constructed from a raw string). `0` is a valid target;
  unset (`nil`) is a distinct state (`BUD-03` later counts unset as zero — not this
  module's concern).

  `sort_order` is set programmatically by `WeddingPlanner.Categories` — appended after
  the current last category on create, swapped between two neighbours by
  `WeddingPlanner.Categories.move_category/3` — and is deliberately absent from
  `changeset/2` so it can never be set through a form.
  """
  use Ecto.Schema

  import Ecto.Changeset

  @type t :: %__MODULE__{}

  schema "categories" do
    field :name, :string
    field :target, Money.Ecto.Map.Type
    field :target_input, :string, virtual: true
    field :sort_order, :integer

    timestamps(type: :utc_datetime)
  end

  @doc """
  Changeset for the user-facing fields (`CST-01`): `name` required, 1–200 characters,
  trimmed. `target_input` (see moduledoc) is parsed via `WeddingPlanner.Money.parse/1`
  into the real `target` field. `sort_order` is intentionally not castable here — see
  `sort_order_changeset/2`.
  """
  @spec changeset(t(), map()) :: Ecto.Changeset.t()
  def changeset(category, attrs) do
    category
    |> cast(attrs, [:name])
    |> update_change(:name, &trim/1)
    |> validate_required([:name])
    |> validate_length(:name, min: 1, max: 200)
    # `empty_values: []` disables `cast/4`'s default treatment of `""` as "field not
    # provided" — `target_input` MUST distinguish an omitted key (leave the stored
    # target alone) from an explicit empty string (clear it back to unset, see
    # `put_target/1`), and the default behaviour collapses both to the same no-op. This
    # is cast in its own call, *after* `:name`'s `validate_required/2` above: `cast/4`'s
    # `:empty_values` option is stored on the changeset as a whole (it also drives
    # `validate_required/2`'s own "is this blank" check, not just this cast call), so
    # casting `:name` first with the default `[""]` is what lets an explicitly blank
    # name still be rejected as "can't be blank" rather than silently ignored.
    |> cast(attrs, [:target_input], empty_values: [])
    |> put_target()
  end

  @doc """
  Programmatic-only changeset for reordering
  (`WeddingPlanner.Categories.move_category/3`). Never driven directly by user input.
  """
  @spec sort_order_changeset(t(), integer()) :: Ecto.Changeset.t()
  def sort_order_changeset(category, sort_order) when is_integer(sort_order) do
    change(category, sort_order: sort_order)
  end

  defp trim(value) when is_binary(value), do: String.trim(value)
  defp trim(value), do: value

  defp put_target(changeset) do
    case get_change(changeset, :target_input) do
      nil ->
        changeset

      "" ->
        put_change(changeset, :target, nil)

      raw when is_binary(raw) ->
        case WeddingPlanner.Money.parse(raw) do
          {:ok, money} -> put_change(changeset, :target, money)
          {:error, message} -> add_error(changeset, :target_input, message)
        end
    end
  end
end
