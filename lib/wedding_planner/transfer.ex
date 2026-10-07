defmodule WeddingPlanner.Transfer do
  @moduledoc """
  Data transfer between two installations of the app (`DR-93`): export everything as one
  JSON file, import such a file to **replace** all data here. The only entry point for the
  web layer; the pieces live under `WeddingPlanner.Transfer.*`.

  ## Export

  `export/1` is `WeddingPlanner.Transfer.Export.build/1`: every transferred table and every
  uploaded file, in the format `WeddingPlanner.Transfer.Document` describes, named by
  `export_filename/2` in the viewer's zone. A read: no activity entry.

  ## Import (`DR-94`, `DR-97`, `DR-98`)

    1. `stash_upload/1` copies the uploaded file into `<transfer_dir>/incoming/` and returns
       a token, so the LiveView holds a token instead of up to 50 MB (`max_upload_bytes/0`).
    2. `preview/2` parses the stash (`WeddingPlanner.Transfer.Document.parse/1`) and
       reports what the import would do (`WeddingPlanner.Transfer.Preview`), writing
       nothing.
    3. `import/3` parses it again and applies it all or nothing
       (`WeddingPlanner.Transfer.Import`): the embedded files first, additively
       (`XC-21`, `DR-29`); then one `BEGIN IMMEDIATE` transaction that saves a **safety
       copy** of the current data, deletes every transferred table, inserts the file's
       rows with their ids and remapped users (`WeddingPlanner.Transfer.UserRemap`,
       `DR-22`), checks foreign keys and writes one activity entry (`XC-10`); after
       commit it deletes the files only the old data used (`DR-30` accepts orphans after
       a crash) and broadcasts `:data_import` so every open screen reloads (`XC-01`,
       `DR-95`). Users, passkeys, sessions and enrollment links are never touched.
    4. `discard/1` drops the stash (cancel). A refused import keeps it until then; a
       successful one discards it itself.

  Every refusal is a `WeddingPlanner.Transfer.Refusal` whose `message` is ready to show.

  ## Safety copies (`DR-97`)

  `list_safety_copies/0` lists them newest first; `safety_copy_path/1` resolves a name for
  the authenticated download, accepting only a well-formed name of an existing regular
  file (no traversal). Importing a safety copy undoes the import that wrote it.
  """

  alias WeddingPlanner.Accounts.Scope
  alias WeddingPlanner.Transfer.Document
  alias WeddingPlanner.Transfer.Export
  alias WeddingPlanner.Transfer.Files
  alias WeddingPlanner.Transfer.Import
  alias WeddingPlanner.Transfer.Preview
  alias WeddingPlanner.Transfer.Refusal
  alias WeddingPlannerWeb.Format

  @type preview :: Preview.t()
  @type result :: Import.result()
  @type safety_copy :: %{name: String.t(), byte_size: non_neg_integer(), saved_at: DateTime.t()}

  @doc """
  The largest import file accepted: 50 000 000 bytes (`DR-97`), the same limit
  `WeddingPlanner.Transfer.Document.parse/1` enforces.
  """
  @spec max_upload_bytes() :: pos_integer()
  def max_upload_bytes, do: Document.max_bytes()

  @doc """
  Copies the uploaded file at `tmp_path` (never moved: the LiveView owns it) into the
  stash and returns its token. The size is re-checked here (`:too_large`). Each call also
  sweeps stashes older than an hour.
  """
  @spec stash_upload(Path.t()) :: {:ok, String.t()} | {:error, Refusal.t()}
  def stash_upload(tmp_path) when is_binary(tmp_path) do
    max = max_upload_bytes()

    case File.stat(tmp_path) do
      {:ok, %File.Stat{type: :regular, size: size}} when size > max ->
        {:error, too_large(max)}

      {:ok, %File.Stat{type: :regular}} ->
        case Files.stash(tmp_path, max) do
          {:ok, token} -> {:ok, token}
          {:error, :too_large} -> {:error, too_large(max)}
          {:error, reason} -> {:error, storage(reason)}
        end

      {:ok, %File.Stat{}} ->
        {:error, storage(:einval)}

      {:error, reason} ->
        {:error, storage(reason)}
    end
  end

  @doc """
  What importing the stash `token` as `scope`'s user would do (`WeddingPlanner.Transfer.Preview`).
  Writes nothing. An unknown or expired token is `:expired`; a file that doesn't parse is
  the parser's refusal.
  """
  @spec preview(String.t(), Scope.t()) :: {:ok, preview()} | {:error, Refusal.t()}
  def preview(token, %Scope{} = scope) do
    with {:ok, document} <- parse_stash(token) do
      {:ok, Preview.build(document, scope)}
    end
  end

  @doc """
  Replaces all data here with the stash `token`'s (see the moduledoc and
  `WeddingPlanner.Transfer.Import`). Options: `origin:` (the importing LiveView's pid, or
  `nil`; that screen is not reloaded by the broadcast), `time_zone:` (the importer's
  zone), `source_host:` (this installation's host, stamped on the safety copy).

  On success the stash is discarded. On a refusal nothing changed, and the stash is kept
  until `discard/1`.
  """
  @spec import(String.t(), Scope.t(), keyword()) :: {:ok, result()} | {:error, Refusal.t()}
  def import(token, %Scope{} = scope, opts) do
    with {:ok, document} <- parse_stash(token),
         {:ok, result} <- Import.run(document, scope, opts) do
      discard(token)
      {:ok, result}
    end
  end

  @doc "Removes the stash `token` (cancel); an unknown token is fine."
  @spec discard(String.t()) :: :ok
  def discard(token), do: Files.discard(token)

  @doc "The export of all data (`WeddingPlanner.Transfer.Export.build/1`). Options: `source_host:`."
  @spec export(keyword()) :: iodata()
  def export(opts), do: Export.build(source_host: Keyword.fetch!(opts, :source_host))

  @doc """
  The export's download name, e.g. `"wedding-planner-25-09-2026-1405.json"` for
  `~U[2026-09-25 12:05:00Z]` in `"Europe/Brussels"`. An unusable zone falls back to the
  default one (`WeddingPlannerWeb.Format.resolve_time_zone/1`).
  """
  @spec export_filename(DateTime.t(), String.t() | nil) :: String.t()
  def export_filename(%DateTime{} = datetime, time_zone) do
    stamp =
      datetime
      |> DateTime.shift_zone!(Format.resolve_time_zone(time_zone))
      |> Calendar.strftime("%d-%m-%Y-%H%M")

    "wedding-planner-" <> stamp <> ".json"
  end

  @doc """
  The safety copies, newest first, each with its `name` (for `safety_copy_path/1`),
  `byte_size` and `saved_at` (the file's modification time, UTC).
  """
  @spec list_safety_copies() :: [safety_copy()]
  def list_safety_copies, do: Files.list_safety_copies()

  @doc """
  The path of the safety copy `name`, only when `name` is a well-formed safety-copy name
  (`wedding-planner-before-import-dd-mm-yyyy-hhmm[-n].json`) of an existing regular file;
  anything else is `:error`.
  """
  @spec safety_copy_path(String.t()) :: {:ok, Path.t()} | :error
  def safety_copy_path(name), do: Files.safety_copy_path(name)

  @doc """
  Deletes the safety copy `name` and logs it against the settings (`XC-10`): "Wannes
  deleted the safety copy of 25/09/2026 14:05". `:error` for a malformed or unknown name;
  nothing is logged then.
  """
  @spec delete_safety_copy(Scope.t(), String.t(), String.t() | nil) :: :ok | :error
  def delete_safety_copy(%Scope{user: user} = scope, name, time_zone \\ nil) do
    copy = Enum.find(Files.list_safety_copies(), &(&1.name == name))

    with %{} <- copy,
         :ok <- Files.delete_safety_copy(name) do
      {:ok, _} =
        WeddingPlanner.Log.entry(
          scope,
          {:settings, WeddingPlanner.Settings.get().id},
          "#{user.display_name} deleted the safety copy of #{Format.datetime(copy.saved_at, time_zone)}"
        )

      :ok
    else
      _ -> :error
    end
  end

  # -- private -----------------------------------------------------------------------------

  defp parse_stash(token) do
    case Files.read_stash(token) do
      {:ok, binary} ->
        Document.parse(binary, max_bytes: max_upload_bytes())

      :error ->
        {:error,
         %Refusal{reason: :expired, message: "That upload has expired — choose the file again."}}
    end
  end

  defp too_large(max) do
    %Refusal{
      reason: :too_large,
      message: "This file is larger than #{div(max, 1_000_000)} MB.",
      detail: %{max_bytes: max}
    }
  end

  defp storage(reason) do
    %Refusal{
      reason: :storage,
      message: "This app couldn't read the uploaded file (#{inspect(reason)}). Try again.",
      detail: reason
    }
  end
end
