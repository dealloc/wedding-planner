defmodule WeddingPlanner.Transfer.Import do
  @moduledoc """
  Applies a parsed transfer document (`WeddingPlanner.Transfer.Document`) as this
  installation's complete new state (`DR-93` (3), `DR-94`, `DR-98`). Internal to
  `WeddingPlanner.Transfer`, which is the only entry point.

  ## The order (all or nothing)

  1. **Users** are remapped by display name (`WeddingPlanner.Transfer.UserRemap`,
     `DR-93` (2), `DR-22`); users, passkeys, sessions and enrollment links are never
     touched (`AUTH-01`…`AUTH-11`).
  2. **Phase 1, files, no database lock (`DR-94`).** Every embedded file is checked
     first: a key already on disk must hold identical bytes (sha256), or the import is
     refused (`:file_conflict`) before anything is written. Then each key not on disk is
     written through `WeddingPlanner.References.Storage.write_imported/2` (`.part` plus
     rename, `XC-21`, `DR-29`). Before commit the uploads dir is a superset serving the
     old data; it is never missing and never swapped.
  3. **Phase 2, one transaction** (`mode: :immediate`, which exqlite turns into
     `BEGIN IMMEDIATE`: the write lock is taken at the start, so the safety copy and the
     replacement see one state and no writer slips in between, `DR-98`):
     `PRAGMA defer_foreign_keys = ON`; the embedded files are re-checked under the lock
     (see "Concurrency"); `old_keys` (the current file references) are read; the
     **safety copy** (`WeddingPlanner.Transfer.Export.build/1` of the current data) is
     written to `safety-copies/` (`DR-97`); every transferred table is deleted in reverse
     registry order, `persons` in two statements (+1s first, so no statement deletes a
     host whose +1 still points at it through the RESTRICT `persons.host_id`); every
     table is inserted in registry order with the file's ids (`Repo.insert_all/2`,
     chunks of 200, no changesets, `DR-96`);
     `PRAGMA foreign_key_check` must come back empty (else `:inconsistent`, naming the
     table and row); and **last** one activity entry through
     `WeddingPlanner.Log.summary/3` with `broadcast: false` (`XC-10`), so its id comes
     after every imported id.
  4. **On any refusal, rollback or raise** the keys phase 1 (or the re-check) newly wrote
     are removed again, never a pre-existing one, and so is the safety copy. The caller
     gets a `WeddingPlanner.Transfer.Refusal`, never an exception: a busy database is
     `:busy`, a database error `:inconsistent`, anything else `:storage` (and logged).
  5. **Phase 3, after commit:** the files only the old data used (`old_keys − new_keys`)
     are deleted, then `{:created, %{origin:, exported_at:, source_host:}}` is broadcast
     on `:data_import`, which remounts every open screen except the importing one
     (`XC-01`, `DR-95`). A crash between commit and prune leaves orphan files, which
     `DR-30` accepts as harmless.

  The imported activity log replaces the old one; the safety copy keeps the old one, and
  importing the safety copy undoes the import (`DR-93` (5)).

  ## Concurrency

  Two imports (or an import and an ordinary save) serialise on SQLite's write lock; no
  global mutex is needed. Files are the only thing outside the transaction, and the rule
  that keeps them consistent in any interleaving is: **a file is only ever deleted while
  holding the write lock, and only when no committed file reference uses it.** Every
  deletion here (the phase 3 prune and the cleanup after a refusal) runs in its own short
  `BEGIN IMMEDIATE` transaction that re-reads the file references first; if the lock
  can't be had, the files are left as orphans (`DR-30`) rather than deleted blindly. And
  every import re-checks, under its own lock, that each of its files is on disk,
  rewriting any that aren't (from the bytes it holds).

  Walk-through with imports A and B running together, both phase 1s first, A committing
  first: A prunes `old_keys(A) − new_keys(A)` under the lock. Either that runs before B's
  transaction, and B's re-check rewrites any file of B's that A's prune took; or it runs
  after B's commit, and every file of B's is referenced then, so it is kept. B then
  prunes `old_keys(B) − new_keys(B)`, where `old_keys(B)` is A's committed state, read
  inside B's transaction. The same holds when A is refused instead: its cleanup takes the
  lock and skips anything referenced. Pruning only `old_keys − new_keys` (never
  "everything unreferenced") also keeps a concurrent upload's not-yet-committed file.
  The one residual window is an ordinary reference delete, whose file removal runs after
  its own commit without the lock (`DR-30`): if an import carrying that same file
  re-checks it in between, the file can go missing, which `DR-30` already serves as a
  404; re-importing heals it.
  """

  import Ecto.Query

  require Logger

  alias WeddingPlanner.Accounts.Scope
  alias WeddingPlanner.Guests.Person
  alias WeddingPlanner.Log
  alias WeddingPlanner.Realtime
  alias WeddingPlanner.References.Reference
  alias WeddingPlanner.References.Storage
  alias WeddingPlanner.Repo
  alias WeddingPlanner.Transfer.Document
  alias WeddingPlanner.Transfer.Export
  alias WeddingPlanner.Transfer.Files
  alias WeddingPlanner.Transfer.Refusal
  alias WeddingPlanner.Transfer.Tables
  alias WeddingPlanner.Transfer.UserRemap
  alias WeddingPlannerWeb.Format

  @chunk_size 200
  @timeout 120_000
  @written_key {__MODULE__, :written}

  @type result :: %{
          safety_copy: String.t(),
          exported_at: DateTime.t(),
          source_host: String.t(),
          counts: [%{key: String.t(), label: String.t(), imported: non_neg_integer()}],
          files_written: non_neg_integer(),
          files_removed: non_neg_integer()
        }

  @doc """
  Imports `document` as `scope`'s user (see the moduledoc). Options: `origin:` (the
  importing LiveView's pid, or `nil`), `time_zone:` (the importer's zone, for the safety
  copy's name and the activity sentence), `source_host:` (this installation's host, for
  the safety copy's header) and, for tests, `now:` (the safety copy's moment).
  """
  @spec run(Document.t(), Scope.t(), keyword()) :: {:ok, result()} | {:error, Refusal.t()}
  def run(%Document{} = document, %Scope{} = scope, opts) do
    # Resolved before the transaction: with no usable zone it reads the settings row.
    time_zone = Format.resolve_time_zone(opts[:time_zone])
    remap = UserRemap.build(document, scope)
    document = UserRemap.rewrite(document, remap.ids)

    with {:ok, to_write} <- plan_files(document.files),
         {:ok, added} <- write_files(to_write, document.files) do
      Process.put(@written_key, %{added: added, safety: nil})

      try do
        document
        |> transact(scope, time_zone, opts)
        |> finish(document, opts)
      after
        Process.delete(@written_key)
      end
    end
  end

  # -- phase 1 -----------------------------------------------------------------------------

  defp plan_files(files) do
    Enum.reduce_while(Enum.sort(files), {:ok, []}, fn {key, file}, {:ok, to_write} ->
      path = Storage.path_for(%{file_key: key, content_type: file.content_type})

      case File.read(path) do
        {:ok, bytes} ->
          if sha256(bytes) == sha256(file.bytes),
            do: {:cont, {:ok, to_write}},
            else: {:halt, {:error, file_conflict(key)}}

        {:error, :enoent} ->
          {:cont, {:ok, [key | to_write]}}

        {:error, reason} ->
          {:halt, {:error, storage(reason)}}
      end
    end)
    |> case do
      {:ok, to_write} -> {:ok, Enum.reverse(to_write)}
      error -> error
    end
  end

  defp write_files(keys, files) do
    Enum.reduce_while(keys, {:ok, []}, fn key, {:ok, added} ->
      %{content_type: content_type, bytes: bytes} = Map.fetch!(files, key)

      case Storage.write_imported(%{file_key: key, content_type: content_type}, bytes) do
        :ok ->
          {:cont, {:ok, [{key, content_type} | added]}}

        {:error, reason} ->
          remove_unreferenced(added)
          {:halt, {:error, storage(reason)}}
      end
    end)
    |> case do
      {:ok, added} -> {:ok, Enum.reverse(added)}
      error -> error
    end
  end

  # -- phase 2 -----------------------------------------------------------------------------

  defp transact(document, scope, time_zone, opts) do
    Repo.transaction(
      fn ->
        Repo.query!("PRAGMA defer_foreign_keys = ON")

        try do
          replace(document, scope, time_zone, opts)
        after
          reset_defer_foreign_keys()
        end
      end,
      mode: :immediate,
      timeout: @timeout
    )
  rescue
    exception ->
      Logger.error(
        "transfer import failed: " <> Exception.format(:error, exception, __STACKTRACE__)
      )

      {:error, refusal_for(exception)}
  end

  defp replace(%Document{meta: meta} = document, scope, time_zone, opts) do
    ensure_files_present!(document.files)
    old_files = current_file_references()

    now = Keyword.get_lazy(opts, :now, fn -> DateTime.utc_now(:second) end)
    safety = Export.build(source_host: Keyword.fetch!(opts, :source_host), now: now)

    safety_copy =
      case Files.write_safety_copy(safety, now, time_zone) do
        {:ok, %{name: name, path: path}} ->
          update_written(&%{&1 | safety: path})
          name

        {:error, reason} ->
          Repo.rollback(storage(reason))
      end

    delete_all()
    insert_all(document)
    check_foreign_keys!()

    description =
      "#{scope.user.display_name} imported data exported " <>
        "#{Format.datetime(meta.exported_at, time_zone)} from #{meta.source_host}"

    case Log.summary(scope, description, broadcast: false) do
      {:ok, _entry} ->
        :ok

      {:error, changeset} ->
        Repo.rollback(%Refusal{
          reason: :inconsistent,
          message: "The import couldn't be logged, so nothing was changed.",
          detail: changeset
        })
    end

    %{safety_copy: safety_copy, old_files: old_files}
  end

  # Under the write lock: every embedded file must be on disk now (another import's
  # prune may have taken a pre-existing one since phase 1, see "Concurrency").
  defp ensure_files_present!(files) do
    for {key, %{content_type: content_type, bytes: bytes}} <- Enum.sort(files),
        not File.regular?(Storage.path_for(%{file_key: key, content_type: content_type})) do
      case Storage.write_imported(%{file_key: key, content_type: content_type}, bytes) do
        :ok -> update_written(&%{&1 | added: &1.added ++ [{key, content_type}]})
        {:error, reason} -> Repo.rollback(storage(reason))
      end
    end

    :ok
  end

  defp current_file_references do
    Repo.all(
      from(r in Reference,
        where: r.kind == :file,
        distinct: true,
        select: {r.file_key, r.content_type}
      )
    )
  end

  # Reverse registry order; persons in two statements, +1s first (DR-98), so no statement
  # ever deletes a host while its +1 (`persons.host_id`, RESTRICT) still exists. DR-98
  # assumes RESTRICT fires immediately even under `PRAGMA defer_foreign_keys`; the bundled
  # SQLite actually defers it too (measured), so this order is what keeps the delete valid
  # should the deferral ever be missing, not what makes it pass today.
  defp delete_all do
    for %{schema: schema} <- Enum.reverse(Tables.transferred()) do
      if schema == Person, do: Repo.delete_all(from(p in Person, where: not is_nil(p.host_id)))
      Repo.delete_all(schema)
    end

    :ok
  end

  defp insert_all(%Document{tables: tables}) do
    for {%{key: key, schema: schema}, rows} <- tables,
        chunk <- Enum.chunk_every(rows, @chunk_size) do
      try do
        Repo.insert_all(schema, chunk)
      rescue
        exception in Exqlite.Error ->
          Repo.rollback(%Refusal{
            reason: :inconsistent,
            message: "This file is damaged: #{key} can't be stored here (#{exception.message}).",
            detail: %{table: key, error: exception.message}
          })
      end
    end

    :ok
  end

  defp check_foreign_keys! do
    case Repo.query!("PRAGMA foreign_key_check") do
      %{rows: []} ->
        :ok

      %{rows: [[table, rowid, parent | _] | _] = rows} ->
        Repo.rollback(%Refusal{
          reason: :inconsistent,
          message: "This file is damaged: #{table} row #{rowid} points at a missing #{parent}.",
          detail: %{violations: rows}
        })
    end
  end

  # PRAGMA defer_foreign_keys switches itself off at COMMIT/ROLLBACK of the outermost
  # transaction; switching it off explicitly also covers a transaction nested in an outer
  # one (the test sandbox), so later statements check foreign keys immediately again.
  defp reset_defer_foreign_keys do
    Repo.query("PRAGMA defer_foreign_keys = OFF")
  rescue
    _ -> :ok
  end

  # -- phase 3 / failure -------------------------------------------------------------------

  defp finish({:ok, %{safety_copy: safety_copy, old_files: old_files}}, document, opts) do
    %{added: added} = Process.get(@written_key)
    new_keys = MapSet.new(file_reference_keys(document))
    removed = remove_unreferenced(Enum.reject(old_files, fn {key, _} -> key in new_keys end))

    Realtime.broadcast_change(
      :data_import,
      {:created,
       %{
         origin: opts[:origin],
         exported_at: document.meta.exported_at,
         source_host: document.meta.source_host
       }}
    )

    {:ok,
     %{
       safety_copy: safety_copy,
       exported_at: document.meta.exported_at,
       source_host: document.meta.source_host,
       counts:
         for {%{preview?: true} = entry, rows} <- document.tables do
           %{key: entry.key, label: entry.label, imported: length(rows)}
         end,
       files_written: length(added),
       files_removed: removed
     }}
  end

  defp finish({:error, reason}, _document, _opts) do
    %{added: added, safety: safety} = Process.get(@written_key)
    remove_unreferenced(added)
    if safety, do: Files.remove_safety_copy(safety)

    case reason do
      %Refusal{} = refusal ->
        {:error, refusal}

      other ->
        Logger.error("transfer import rolled back: #{inspect(other)}")
        {:error, storage(other)}
    end
  end

  # Deletes the given files that no committed file reference uses, under the write lock
  # (see "Concurrency"). Returns how many it deleted. Busy or failing: logged, the files
  # stay as orphans (DR-30).
  defp remove_unreferenced([]), do: 0

  defp remove_unreferenced(files) do
    keys = files |> Enum.map(&elem(&1, 0)) |> Enum.uniq()

    {:ok, count} =
      Repo.transaction(
        fn ->
          referenced =
            Repo.all(
              from(r in Reference,
                where: r.kind == :file and r.file_key in ^keys,
                select: r.file_key
              )
            )
            |> MapSet.new()

          doomed =
            files |> Enum.uniq_by(&elem(&1, 0)) |> Enum.reject(&(elem(&1, 0) in referenced))

          Enum.each(doomed, fn {key, content_type} ->
            Storage.delete(%{file_key: key, content_type: content_type})
          end)

          length(doomed)
        end,
        mode: :immediate
      )

    count
  rescue
    exception ->
      Logger.warning(
        "transfer: left #{length(files)} file(s) in place as orphans: " <>
          Exception.message(exception)
      )

      0
  end

  defp file_reference_keys(%Document{tables: tables}) do
    for {%{schema: Reference}, rows} <- tables,
        %{kind: :file, file_key: key} <- rows,
        do: key
  end

  # -- helpers -----------------------------------------------------------------------------

  defp update_written(fun), do: Process.put(@written_key, fun.(Process.get(@written_key)))

  defp sha256(bytes), do: :crypto.hash(:sha256, bytes)

  @doc false
  # The refusal for an exception raised by the transaction (public for its unit test).
  @spec refusal_for(Exception.t()) :: Refusal.t()
  def refusal_for(%Exqlite.Error{message: message} = exception) do
    if message =~ ~r/busy|locked/i do
      %Refusal{
        reason: :busy,
        message: "The other user was saving at that moment — try again.",
        detail: message
      }
    else
      %Refusal{
        reason: :inconsistent,
        message: "This file can't be stored here: #{message}. Nothing was changed.",
        detail: exception
      }
    end
  end

  def refusal_for(exception) do
    %Refusal{
      reason: :storage,
      message: "The import failed on this installation, so nothing was changed.",
      detail: Exception.message(exception)
    }
  end

  defp file_conflict(key) do
    %Refusal{
      reason: :file_conflict,
      message:
        "This file can't be imported: it carries an uploaded file (#{key}) that is already " <>
          "stored here with different contents. Nothing was changed.",
      detail: %{file_key: key}
    }
  end

  defp storage(reason) do
    %Refusal{
      reason: :storage,
      message:
        "This app couldn't write a file to its disk (#{inspect(reason)}), so nothing was changed.",
      detail: reason
    }
  end
end
