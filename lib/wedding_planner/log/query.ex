defmodule WeddingPlanner.Log.Query do
  @moduledoc """
  Read-side queries over `WeddingPlanner.Log.Entry`, built for the global activity log
  view and the per-entity history component (task 20; `docs/04-cross-cutting.md` `XC-11`,
  `XC-12`).

  `WeddingPlanner.Log` itself only writes (`XC-13` — the log is read-only, and that
  module deliberately exposes no query beyond `resolve/1`). This module is the reader,
  kept separate on purpose so the write-through service task 19 built stays exactly as
  it was verified.

  ## Top-level vs. children (`XC-12`)

  A bulk action (`WeddingPlanner.Log.action/3`) writes one summarising entry
  (`entity_type` `nil`, `parent_id` `nil`) plus one child entry per affected entity
  (`entity_type` set, `parent_id` pointing at the summary). `list/1` returns only
  **top-level** entries — standalone entries and summaries, never a summary's children —
  which is what lets the global log collapse children under their summary and fetch them
  lazily with `children/1`. `for_entity/2`, by contrast, deliberately does **not**
  restrict on `parent_id`: a bulk child carries the same `entity_type`/`entity_id` as a
  standalone entry, so it is included automatically, which is exactly what makes a
  per-entity history complete per `XC-12`.

  ## Filtering (`XC-11`) and what a summary matches

  `list/1` filters (`user_id`, `entity_type`, `from`/`to`) are applied to each top-level
  entry's own fields. A summarising entry has no `entity_type` of its own, so an active
  `entity_type` filter naturally excludes it — matching a summary because *some child*
  happens to match was considered and deliberately not built (unstated scope; flagged in
  the task 20 report rather than decided silently). `matches_filters?/2` mirrors the same
  predicate for a single, already-fetched entry (used to decide whether a live-broadcast
  entry should be inserted into an already-filtered view).
  """

  import Ecto.Query

  alias WeddingPlanner.Accounts.User
  alias WeddingPlanner.Log.Entry
  alias WeddingPlanner.Repo

  @default_limit 200

  @type filters :: %{
          optional(:user_id) => integer(),
          optional(:entity_type) => String.t(),
          optional(:from) => DateTime.t(),
          optional(:to) => DateTime.t(),
          optional(:limit) => pos_integer()
        }

  @doc """
  Lists top-level activity entries (`XC-11`), newest first, optionally filtered by
  `:user_id`, `:entity_type` and/or a `:from`/`:to` UTC `DateTime.t()` range (inclusive).
  `:limit` defaults to #{@default_limit} — this app has exactly two users and no
  pagination UI was asked for (task 20); flagged as the minimal choice rather than
  building pagination nothing asked for.
  """
  @spec list(filters()) :: [Entry.t()]
  def list(filters \\ %{}) do
    Entry
    |> where([e], is_nil(e.parent_id))
    |> apply_filters(filters)
    |> order_by([e], desc: e.inserted_at, desc: e.id)
    |> limit(^Map.get(filters, :limit, @default_limit))
    |> preload(:user)
    |> Repo.all()
  end

  @doc """
  Lists a bulk summary's children (`XC-12`), oldest first (the order they were written
  in), `:user` preloaded.
  """
  @spec children(term()) :: [Entry.t()]
  def children(summary_id) do
    Entry
    |> where([e], e.parent_id == ^summary_id)
    |> order_by([e], asc: e.inserted_at, asc: e.id)
    |> preload(:user)
    |> Repo.all()
  end

  @doc """
  Counts children per summary, for the summary ids in `summary_ids`. Returns a map
  `%{summary_id => count}`; a summary with no children yet is simply absent from the
  map (treat a missing key as `0`).
  """
  @spec children_counts([term()]) :: %{optional(term()) => non_neg_integer()}
  def children_counts([]), do: %{}

  def children_counts(summary_ids) do
    Entry
    |> where([e], e.parent_id in ^summary_ids)
    |> group_by([e], e.parent_id)
    |> select([e], {e.parent_id, count(e.id)})
    |> Repo.all()
    |> Map.new()
  end

  @doc """
  Lists every entry for one entity (`XC-11`'s per-entity view), newest first, including
  bulk-action children (`XC-12` — see moduledoc). `:user` preloaded.
  """
  @spec for_entity(atom() | String.t(), term()) :: [Entry.t()]
  def for_entity(type, id) when is_atom(type), do: for_entity(to_string(type), id)

  def for_entity(type, id) when is_binary(type) do
    Entry
    |> where([e], e.entity_type == ^type and e.entity_id == ^id)
    |> order_by([e], desc: e.inserted_at, desc: e.id)
    |> preload(:user)
    |> Repo.all()
  end

  @doc "Every user, ordered by display name — the global log's user filter options."
  @spec list_users() :: [User.t()]
  def list_users do
    User |> order_by(asc: :display_name) |> Repo.all()
  end

  @doc """
  The distinct entity types that have ever been logged, ordered alphabetically — the
  global log's entity-type filter options. A bulk summary's `nil` entity_type is
  excluded.
  """
  @spec list_entity_types() :: [String.t()]
  def list_entity_types do
    Entry
    |> where([e], not is_nil(e.entity_type))
    |> distinct(true)
    |> select([e], e.entity_type)
    |> order_by([e], asc: e.entity_type)
    |> Repo.all()
  end

  @doc "Fetches one entry by id, `:user` preloaded. Raises if it does not exist."
  @spec get!(term()) :: Entry.t()
  def get!(id), do: Entry |> Repo.get!(id) |> Repo.preload(:user)

  @doc "Preloads `:user` on an already-fetched (e.g. freshly broadcast) entry."
  @spec preload_user(Entry.t()) :: Entry.t()
  def preload_user(%Entry{} = entry), do: Repo.preload(entry, :user)

  @doc """
  Whether a single, already-fetched top-level entry matches `filters` — the same
  predicate `list/1`'s query applies, used to decide whether a live-broadcast entry
  belongs in an already-filtered view. See the moduledoc for what a bulk summary
  matches.
  """
  @spec matches_filters?(Entry.t(), filters()) :: boolean()
  def matches_filters?(%Entry{} = entry, filters) do
    matches_user?(entry, Map.get(filters, :user_id)) and
      matches_entity_type?(entry, Map.get(filters, :entity_type)) and
      matches_range?(entry, Map.get(filters, :from), Map.get(filters, :to))
  end

  defp matches_user?(_entry, nil), do: true
  defp matches_user?(entry, user_id), do: entry.user_id == user_id

  defp matches_entity_type?(_entry, nil), do: true
  defp matches_entity_type?(entry, type), do: entry.entity_type == type

  defp matches_range?(entry, from, to) do
    (is_nil(from) or DateTime.compare(entry.inserted_at, from) != :lt) and
      (is_nil(to) or DateTime.compare(entry.inserted_at, to) != :gt)
  end

  defp apply_filters(query, filters) do
    query
    |> filter_user(Map.get(filters, :user_id))
    |> filter_entity_type(Map.get(filters, :entity_type))
    |> filter_from(Map.get(filters, :from))
    |> filter_to(Map.get(filters, :to))
  end

  defp filter_user(query, nil), do: query
  defp filter_user(query, user_id), do: where(query, [e], e.user_id == ^user_id)

  defp filter_entity_type(query, nil), do: query
  defp filter_entity_type(query, type), do: where(query, [e], e.entity_type == ^type)

  defp filter_from(query, nil), do: query
  defp filter_from(query, from), do: where(query, [e], e.inserted_at >= ^from)

  defp filter_to(query, nil), do: query
  defp filter_to(query, to), do: where(query, [e], e.inserted_at <= ^to)
end
