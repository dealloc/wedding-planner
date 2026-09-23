defmodule WeddingPlanner.Tasks.Dependency do
  @moduledoc """
  A single task-dependency edge (`docs/modules/tasks-and-timeline.md` TSK-10, `06-
  decisions.md` DR-35/DR-36, task 42).

  `task_id` waits on `depends_on_id` — the latter is the prerequisite (`DR-35`'s
  direction, mirrored in `WeddingPlanner.Tasks.Graph`'s moduledoc). Both ids are set
  programmatically by `WeddingPlanner.Tasks` (`%__MODULE__{task_id: ..., depends_on_id:
  ...}`), never cast from external input — this schema's `changeset/2` only validates
  *structure* (both present, not equal to each other). Existence of both tasks,
  duplicate-edge detection and cycle rejection all need a query or the pure
  `WeddingPlanner.Tasks.Graph` engine, so they live in the context, not here — the same
  division `WeddingPlanner.Guests`' moduledoc documents for `group_id`.
  """
  use Ecto.Schema

  import Ecto.Changeset

  alias WeddingPlanner.Tasks.Task

  @type t :: %__MODULE__{}

  schema "task_dependencies" do
    belongs_to :task, Task
    belongs_to :depends_on, Task

    timestamps(type: :utc_datetime, updated_at: false)
  end

  @doc """
  Structural changeset: both `task_id` and `depends_on_id` present and distinct. Does
  **not** check that either id refers to an existing task, that the edge doesn't already
  exist, or that it wouldn't close a cycle — see the moduledoc.
  """
  @spec changeset(t(), map()) :: Ecto.Changeset.t()
  def changeset(dependency, attrs \\ %{}) do
    dependency
    |> cast(attrs, [])
    |> validate_required([:task_id, :depends_on_id])
    |> validate_distinct()
  end

  defp validate_distinct(changeset) do
    task_id = get_field(changeset, :task_id)
    depends_on_id = get_field(changeset, :depends_on_id)

    if task_id && depends_on_id && task_id == depends_on_id do
      add_error(changeset, :depends_on_id, "can't depend on itself")
    else
      changeset
    end
  end
end
