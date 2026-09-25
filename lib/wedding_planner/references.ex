defmodule WeddingPlanner.References do
  @moduledoc """
  References on offers and invoices (`docs/04-cross-cutting.md` `XC-20` through `XC-24`),
  resource `:reference`. A reference has a label and either an uploaded file or a URL
  (`XC-20`). This is slice B1's owner-agnostic data layer; the serving controller and the
  UI component are tasks 39 and 40.

  ## The owner contract (`DR-28`)

  Offers (C2) and invoices (B2) do not exist yet, so nothing here names them. Every
  function takes a `WeddingPlanner.References.Owner` — `attrs` go on new rows and scope
  every query, activity entries are written against `log_entity` (the owner, so its own
  history shows its attachments, `XC-11`), and `name` reads in log sentences. See that
  module for what C2/B2 must supply. `update_reference/4` and `delete_reference/3`
  refuse (`{:error, :not_owned}`) a reference whose row does not match `owner.attrs`, so
  a stale client can never log against the wrong owner.

  ## Upload rules (`DR-29`)

  `WeddingPlanner.References.Storage` decides a file's type from its bytes (PDF, PNG,
  JPEG, WebP — `XC-21`), enforces 10 MiB, and names the file with a random key. A blank
  label on upload defaults to the original filename; URL references are `http`/`https`
  only (`WeddingPlanner.References.Reference`).

  ## Deletion (`DR-30`, `XC-24`)

  The row is deleted and logged first; the file is removed only after that has committed.
  A crash in between leaves a harmless orphan file; a file that is already gone is not an
  error. Deleting an owner is a two-step contract, mirroring
  `WeddingPlanner.Tasks.detach_event/2`:

   1. **Inside** the owner's own `WeddingPlanner.Log.action/3`, before deleting the owner
      row, call `delete_owner_references/2`. It deletes every reference row, writes one
      child entry each, does **not** broadcast and does **not** touch files — so if the
      owner's transaction rolls back, every row and every file is still there.
   2. **After** the transaction commits, call `purge_deleted/1` with what step 1 returned:
      it broadcasts `{:deleted, id}` for each and removes their files.

  `reference_deletion_effects/1` feeds the owner's `destructive_confirm/1` (`XC-24`,
  `XC-40`).

  ## Backups (`NFR-04`, `D-32`)

  Nothing to do here: backing up the uploads directory is deployment's job (NFR-04). A
  one-way sync removes a deleted file from the backup at its next run, consistent with
  `XC-24`.

  ## Live updates (`XC-01`)

  `{:created, reference}`, `{:updated, reference}` and `{:deleted, id}` on
  `Realtime.topic(:reference)` — the host view subscribes and re-lists its owner's
  references.
  """

  import Ecto.Query

  alias WeddingPlanner.Accounts.Scope
  alias WeddingPlanner.Accounts.User
  alias WeddingPlanner.Log
  alias WeddingPlanner.Realtime
  alias WeddingPlanner.References.Owner
  alias WeddingPlanner.References.Reference
  alias WeddingPlanner.References.Storage
  alias WeddingPlanner.Repo

  @resource :reference

  @doc "The owner's references, oldest first (`inserted_at`, then `id`)."
  @spec list_references(Owner.t()) :: [Reference.t()]
  def list_references(%Owner{} = owner) do
    owner
    |> owner_query()
    |> order_by([r], asc: r.inserted_at, asc: r.id)
    |> Repo.all()
  end

  @doc "Fetches one reference by id. Raises `Ecto.NoResultsError` if it does not exist."
  @spec get_reference!(term()) :: Reference.t()
  def get_reference!(id), do: Repo.get!(Reference, id)

  @doc """
  Fetches one reference by id, or `nil` if there is none. An id that is not an integer
  (e.g. `"abc"` from a URL) is `nil` too rather than an `Ecto.Query.CastError`, so the
  file-serving controller (`DR-30`) can answer 404 for anything it cannot find.
  """
  @spec get_reference(term()) :: Reference.t() | nil
  def get_reference(id) do
    case Ecto.Type.cast(:id, id) do
      {:ok, id} -> Repo.get(Reference, id)
      :error -> nil
    end
  end

  @doc """
  Attaches an uploaded file to `owner` (`XC-20`, `XC-21`, `DR-29`).

  `{temp_path, original_name}` is the upload: `temp_path` is copied into storage
  (`Storage.store/2` — type sniffed from the bytes, size checked) **before** the row is
  inserted; if the insert then fails (e.g. a label over 200 characters) or raises, the
  stored file is removed again, so a failed create never leaves a file behind. `attrs`
  may carry `"label"`; blank defaults to the original filename.

  Logs "Wannes attached 'Quote' (PDF) to offer 'Venue A'" against `owner.log_entity`
  and broadcasts `{:created, reference}`.
  """
  @spec create_file_reference(Scope.t(), Owner.t(), map(), {Path.t(), String.t()}) ::
          {:ok, Reference.t()}
          | {:error, Ecto.Changeset.t()}
          | {:error, Storage.store_error()}
  def create_file_reference(%Scope{} = scope, %Owner{} = owner, attrs, {temp_path, original_name}) do
    with {:ok, stored} <- Storage.store(temp_path, original_name),
         {:ok, reference} <- insert_stored(owner, attrs, stored) do
      log(
        scope,
        owner,
        "attached '#{reference.label}' (#{Storage.type_label(reference.content_type)}) to #{owner.name}"
      )

      Realtime.broadcast_change(@resource, {:created, reference})
      {:ok, reference}
    end
  end

  @doc """
  Adds a URL reference to `owner` (`XC-20`; `http`/`https` only, `DR-29`). Logs "Wannes
  added link 'Venue website' to offer 'Venue A'" and broadcasts `{:created, reference}`.
  """
  @spec create_url_reference(Scope.t(), Owner.t(), map()) ::
          {:ok, Reference.t()} | {:error, Ecto.Changeset.t()}
  def create_url_reference(%Scope{} = scope, %Owner{} = owner, attrs) do
    owner
    |> new_reference()
    |> Reference.url_changeset(attrs)
    |> Repo.insert()
    |> case do
      {:ok, reference} ->
        log(scope, owner, "added link '#{reference.label}' to #{owner.name}")
        Realtime.broadcast_change(@resource, {:created, reference})
        {:ok, reference}

      error ->
        error
    end
  end

  @doc "A changeset for an edit form (`Reference.label_changeset/2`) — never persists."
  @spec change_reference(Reference.t(), map()) :: Ecto.Changeset.t()
  def change_reference(%Reference{} = reference, attrs \\ %{}) do
    Reference.label_changeset(reference, attrs)
  end

  @doc """
  Renames a reference, and for a URL reference may change its URL. One entry per changed
  field (`XC-10`): "Wannes renamed reference 'Quote' on offer 'Venue A' to 'Final
  quote'" / "Wannes changed the URL of reference 'Venue website' on offer 'Venue A':
  old → new". Broadcasts `{:updated, reference}`. `{:error, :not_owned}` if the reference
  does not belong to `owner`.
  """
  @spec update_reference(Scope.t(), Owner.t(), Reference.t(), map()) ::
          {:ok, Reference.t()} | {:error, Ecto.Changeset.t()} | {:error, :not_owned}
  def update_reference(%Scope{} = scope, %Owner{} = owner, %Reference{} = reference, attrs) do
    with :ok <- check_owned(owner, reference),
         changeset = Reference.label_changeset(reference, attrs),
         {:ok, updated} <- Repo.update(changeset) do
      if Map.has_key?(changeset.changes, :label) do
        log(
          scope,
          owner,
          "renamed reference '#{reference.label}' on #{owner.name} to '#{updated.label}'"
        )
      end

      if Map.has_key?(changeset.changes, :url) do
        log(
          scope,
          owner,
          "changed the URL of reference '#{reference.label}' on #{owner.name}: #{reference.url} → #{updated.url}"
        )
      end

      Realtime.broadcast_change(@resource, {:updated, updated})
      {:ok, updated}
    end
  end

  @doc """
  Deletes one reference (`DR-30`): the row is deleted and "Wannes removed reference
  'Quote' from offer 'Venue A'" logged, `{:deleted, id}` broadcast, and only then the
  file removed. A file that is already missing is not an error. `{:error, :not_owned}`
  if the reference does not belong to `owner`.
  """
  @spec delete_reference(Scope.t(), Owner.t(), Reference.t()) ::
          {:ok, Reference.t()} | {:error, Ecto.Changeset.t()} | {:error, :not_owned}
  def delete_reference(%Scope{} = scope, %Owner{} = owner, %Reference{} = reference) do
    with :ok <- check_owned(owner, reference),
         {:ok, deleted} <- Repo.delete(reference) do
      log(scope, owner, "removed reference '#{deleted.label}' from #{owner.name}")
      Realtime.broadcast_change(@resource, {:deleted, deleted.id})
      :ok = Storage.delete(deleted)
      {:ok, deleted}
    end
  end

  @doc """
  `XC-24`, step 1 of 2: deletes every reference of `owner`, writing one entry each —
  "Wannes removed reference 'Quote' (offer 'Venue A' deleted)" — and returns the deleted
  references.

  **Must be called inside the owner's own enclosing `WeddingPlanner.Log.action/3`**,
  before the owner row is deleted: every `Log.entry/3` here relies on that action's
  summary and transaction to become its children and to be atomic with the owner's
  deletion. This function does not start a transaction, does **not** broadcast and does
  **not** touch files — if the owner's transaction rolls back, nothing on disk has
  changed. Once it commits, the caller passes the returned list to `purge_deleted/1`.
  """
  @spec delete_owner_references(Scope.t(), Owner.t()) :: [Reference.t()]
  def delete_owner_references(%Scope{} = scope, %Owner{} = owner) do
    owner
    |> list_references()
    |> Enum.map(fn reference ->
      deleted = Repo.delete!(reference)
      log(scope, owner, "removed reference '#{deleted.label}' (#{owner.name} deleted)")
      deleted
    end)
  end

  @doc """
  `XC-24`, step 2 of 2: call **after** the owner's transaction has committed, with what
  `delete_owner_references/2` returned. Broadcasts `{:deleted, id}` for each reference
  and removes their files (`DR-30`; missing files are not an error).
  """
  @spec purge_deleted([Reference.t()]) :: :ok
  def purge_deleted(references) when is_list(references) do
    Enum.each(references, &Realtime.broadcast_change(@resource, {:deleted, &1.id}))
    Storage.delete_files(references)
  end

  @doc """
  What deleting `owner` does to its references, for its `destructive_confirm/1` (`XC-24`,
  `XC-40`): `[]` when it has none, otherwise one entry, e.g.
  `%{label: "3 references are deleted (2 files, 1 link)", count: 3}`.
  """
  @spec reference_deletion_effects(Owner.t()) :: [%{label: String.t(), count: pos_integer()}]
  def reference_deletion_effects(%Owner{} = owner) do
    counts =
      owner
      |> owner_query()
      |> group_by([r], r.kind)
      |> select([r], {r.kind, count(r.id)})
      |> Repo.all()
      |> Map.new()

    files = Map.get(counts, :file, 0)
    links = Map.get(counts, :url, 0)

    case files + links do
      0 ->
        []

      total ->
        parts =
          [{files, "file"}, {links, "link"}]
          |> Enum.reject(fn {n, _} -> n == 0 end)
          |> Enum.map_join(", ", fn {n, word} -> "#{n} #{pluralize(n, word)}" end)

        verb = if total == 1, do: "is", else: "are"

        [
          %{
            label: "#{total} #{pluralize(total, "reference")} #{verb} deleted (#{parts})",
            count: total
          }
        ]
    end
  end

  # -- private -------------------------------------------------------------------------

  defp owner_query(%Owner{attrs: attrs}), do: where(Reference, ^Enum.to_list(attrs))

  # `struct!/2`, not `struct/2`: an owner FK the schema does not (yet) know must raise
  # rather than be silently dropped — an ownerless row would break B2's CHECK (DR-28).
  defp new_reference(%Owner{attrs: attrs}), do: struct!(Reference, attrs)

  defp insert_stored(owner, attrs, stored) do
    result =
      owner
      |> new_reference()
      |> struct!(stored)
      |> Reference.file_changeset(attrs)
      |> Repo.insert()

    case result do
      {:ok, reference} ->
        {:ok, reference}

      {:error, changeset} ->
        :ok = Storage.delete(stored)
        {:error, changeset}
    end
  rescue
    exception ->
      :ok = Storage.delete(stored)
      reraise exception, __STACKTRACE__
  end

  defp check_owned(%Owner{attrs: attrs}, %Reference{} = reference) do
    if Enum.all?(attrs, fn {key, value} -> Map.get(reference, key) == value end),
      do: :ok,
      else: {:error, :not_owned}
  end

  defp log(%Scope{} = scope, %Owner{log_entity: entity}, sentence) do
    {:ok, _} = Log.entry(scope, entity, "#{actor(scope)} #{sentence}")
  end

  defp pluralize(1, word), do: word
  defp pluralize(_n, word), do: word <> "s"

  defp actor(%Scope{user: %User{display_name: name}}), do: name
end
