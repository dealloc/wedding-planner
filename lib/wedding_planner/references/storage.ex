defmodule WeddingPlanner.References.Storage do
  @moduledoc """
  Local file storage for uploaded references (`docs/04-cross-cutting.md` `XC-21`,
  `XC-23`; `DR-29`, `DR-30`). Files live flat in `:uploads_dir` — on the same persistent
  volume as the database, never an object store (`XC-23`). This module does no database
  work; `WeddingPlanner.References` owns the rows.

  `:uploads_dir` is read at call time (`Application.fetch_env!/2`): `UPLOADS_PATH` in
  prod, `tmp/uploads/{dev,test}` in dev/test. It is created on demand before a write
  because dev has no release `migrate` step to create it.

  ## Upload rules (`DR-29`)

    * **Type from the bytes.** Only the first 12 bytes are read and matched against the
      magic numbers of the four allowed types (`sniff/1`) — the client's filename and MIME
      type are never consulted. The stored `content_type` and the on-disk extension both
      come from the sniff, so a PNG uploaded as `photo.jpg` is stored as `image/png`,
      `.png`, and an HTML page named `quote.pdf` is refused.
    * **Size.** At most `max_bytes/0` = 10 MiB = 10 485 760 bytes, checked with
      `File.stat/1` even though the LiveView upload enforces it too, and again on the
      copy itself (at most `max_bytes/0` + 1 bytes are ever copied, so a file that grows
      after the stat cannot slip through). Empty files are refused.
    * **Naming.** `<dir>/<key>.<ext>` where `key` is 16 random bytes, URL-safe base64
      without padding (22 characters of `[A-Za-z0-9_-]`). The original filename is
      sanitised and returned for storage in the database as the download name only — it
      is never part of a path. `path_for/1` re-validates the key and the type before
      joining anything (defence in depth: a corrupted row cannot point outside the dir).
    * **Atomic write.** The upload is copied to `<key>.<ext>.part` and then renamed into
      place (atomic on one volume), so a crash mid-copy never leaves a truncated file
      under a real name; a failed copy or rename removes the `.part`.

  ## Deletion (`DR-30`, `XC-24`)

  `delete/1` and `delete_files/1` run **after** the row's deletion has committed. A crash
  in between leaves an orphan file — harmless (nothing points at it) and accepted. A file
  that is already missing is not an error: it is logged as a warning and `:ok` returned.

  ## Backups (`NFR-04`, `D-32`)

  Nothing to do here: backing up this directory is deployment's job (NFR-04). A one-way
  sync removes a deleted file from the backup at its next run too — which is exactly
  what `XC-24` intends.
  """

  require Logger

  @max_bytes 10 * 1024 * 1024
  @sniff_bytes 12
  @file_name_max 200
  @key_pattern ~r/\A[A-Za-z0-9_-]{22}\z/

  @types [
    %{content_type: "application/pdf", extension: "pdf", label: "PDF"},
    %{content_type: "image/png", extension: "png", label: "PNG"},
    %{content_type: "image/jpeg", extension: "jpg", label: "JPEG"},
    %{content_type: "image/webp", extension: "webp", label: "WebP"}
  ]

  @ext_by_type Map.new(@types, &{&1.content_type, &1.extension})
  @label_by_type Map.new(@types, &{&1.content_type, &1.label})

  @type stored :: %{
          file_key: String.t(),
          file_name: String.t(),
          content_type: String.t(),
          byte_size: pos_integer()
        }

  @type store_error :: :too_large | :unsupported_type | :empty | File.posix()

  @doc "The maximum upload size in bytes: 10 MiB = 10 485 760 (`XC-21`, `DR-29`)."
  @spec max_bytes() :: pos_integer()
  def max_bytes, do: @max_bytes

  @doc """
  The four allowed types (`XC-21`), each with its `content_type`, stored `extension` and
  human `label` (used in log wording).
  """
  @spec allowed_types() :: [%{content_type: String.t(), extension: String.t(), label: String.t()}]
  def allowed_types, do: @types

  @doc "The human label for a stored content type (\"PDF\", \"PNG\", \"JPEG\", \"WebP\")."
  @spec type_label(String.t()) :: String.t()
  def type_label(content_type), do: Map.fetch!(@label_by_type, content_type)

  @doc """
  Decides a file's type from its first bytes (`DR-29`): PDF `%PDF-`; PNG
  `89 50 4E 47 0D 0A 1A 0A`; JPEG `FF D8 FF`; WebP `RIFF` + 4 bytes + `WEBP`. Anything
  else — including HEIC, which is out of scope (`DR-12`) — is `:error`.
  """
  @spec sniff(binary()) :: {:ok, String.t(), String.t()} | :error
  def sniff(<<"%PDF-", _::binary>>), do: {:ok, "application/pdf", "pdf"}

  def sniff(<<0x89, "PNG", 0x0D, 0x0A, 0x1A, 0x0A, _::binary>>),
    do: {:ok, "image/png", "png"}

  def sniff(<<0xFF, 0xD8, 0xFF, _::binary>>), do: {:ok, "image/jpeg", "jpg"}
  def sniff(<<"RIFF", _::binary-size(4), "WEBP", _::binary>>), do: {:ok, "image/webp", "webp"}
  def sniff(_), do: :error

  @doc """
  Stores the file at `temp_path` (e.g. a LiveView upload's temp file, which is copied,
  not moved) under a fresh random key. Checks, in order: the file can be stat'ed and is
  not empty and not over `max_bytes/0`; its first bytes sniff as an allowed type. Only
  then is it copied in (`.part` + rename).

  `original_name` is sanitised (`sanitize_file_name/2`) and returned as `file_name` for
  the database; it never influences the path.
  """
  @spec store(Path.t(), String.t()) :: {:ok, stored()} | {:error, store_error()}
  def store(temp_path, original_name) when is_binary(temp_path) and is_binary(original_name) do
    with :ok <- check_size(temp_path),
         {:ok, content_type, ext} <- sniff_file(temp_path),
         stored = %{file_key: new_key(), content_type: content_type},
         {:ok, bytes} <- copy_into_place(temp_path, path_for(stored)) do
      {:ok,
       Map.merge(stored, %{byte_size: bytes, file_name: sanitize_file_name(original_name, ext)})}
    end
  end

  @doc """
  The absolute path of a stored file — accepts a
  `WeddingPlanner.References.Reference` or `store/2`'s result (anything with `file_key`
  and `content_type`).

  Raises `ArgumentError` unless the key is exactly 22 characters of `[A-Za-z0-9_-]` and
  the content type is one of the four allowed ones, so it can never produce a path
  outside `:uploads_dir` (`DR-29`).
  """
  @spec path_for(%{
          required(:file_key) => String.t() | nil,
          required(:content_type) => String.t() | nil,
          optional(atom()) => term()
        }) :: Path.t()
  def path_for(%{file_key: key, content_type: content_type}) do
    ext = Map.get(@ext_by_type, content_type)

    cond do
      not (is_binary(key) and Regex.match?(@key_pattern, key)) ->
        raise ArgumentError, "invalid reference file key: #{inspect(key)}"

      is_nil(ext) ->
        raise ArgumentError, "invalid reference content type: #{inspect(content_type)}"

      true ->
        Path.join(uploads_dir(), key <> "." <> ext)
    end
  end

  @doc "Whether the stored file for `reference` is present on disk."
  @spec exists?(map()) :: boolean()
  def exists?(reference), do: File.regular?(path_for(reference))

  @doc """
  Removes the stored file for `reference` (`DR-30`). A reference without a file (a URL
  reference) is a no-op. A missing file, or any other removal failure, is logged as a
  warning — the row is already gone, so the worst case is a harmless orphan file.
  """
  @spec delete(map()) :: :ok
  def delete(%{file_key: nil}), do: :ok

  def delete(reference) do
    path = path_for(reference)

    case File.rm(path) do
      :ok ->
        :ok

      {:error, :enoent} ->
        Logger.warning("reference file already missing on delete: #{path}")
        :ok

      {:error, reason} ->
        Logger.warning("could not delete reference file #{path}: #{inspect(reason)}")
        :ok
    end
  end

  @doc "`delete/1` for each reference (`XC-24`'s cascade, after commit)."
  @spec delete_files([map()]) :: :ok
  def delete_files(references) when is_list(references) do
    Enum.each(references, &delete/1)
  end

  @doc """
  Writes an **imported** file's bytes under its own key (`DR-94`, data transfer): the
  only writer to `:uploads_dir` besides `store/2`. The key and bytes come from an import
  file that `WeddingPlanner.Transfer.Document.parse/1` already validated, and are checked
  again here with the same rules as an upload (`DR-29`): the key pattern and an allowed
  type (`path_for/1`), 1 byte to `max_bytes/0`, and the bytes must sniff (`sniff/1`) as
  `content_type`.

  It never overwrites: a file already under that name is `{:error, :exists}` (the import
  checks for identical bytes itself before calling this). The bytes go to
  `<key>.<ext>.part` first and are renamed into place, so a crash never leaves a truncated
  file under a real name; a failure removes the `.part`.
  """
  @spec write_imported(%{file_key: String.t(), content_type: String.t()}, binary()) ::
          :ok | {:error, :exists | :too_large | :unsupported_type | :empty | File.posix()}
  def write_imported(%{file_key: key, content_type: content_type}, bytes)
      when is_binary(bytes) do
    cond do
      not Map.has_key?(@ext_by_type, content_type) -> {:error, :unsupported_type}
      not (is_binary(key) and Regex.match?(@key_pattern, key)) -> {:error, :einval}
      byte_size(bytes) == 0 -> {:error, :empty}
      byte_size(bytes) > @max_bytes -> {:error, :too_large}
      not match?({:ok, ^content_type, _ext}, sniff(bytes)) -> {:error, :unsupported_type}
      true -> write_new(path_for(%{file_key: key, content_type: content_type}), bytes)
    end
  end

  defp write_new(destination, bytes) do
    part = destination <> ".part"

    with :ok <- File.mkdir_p(Path.dirname(destination)),
         false <- File.exists?(destination),
         :ok <- File.write(part, bytes),
         :ok <- File.rename(part, destination) do
      :ok
    else
      true ->
        {:error, :exists}

      {:error, reason} ->
        _ = File.rm(part)
        {:error, reason}
    end
  end

  @doc """
  Makes a client-supplied filename safe to **store** (never to use as a path): keeps only
  the last segment after any `/` or `\\`, strips control characters, trims, caps the
  length at #{@file_name_max} characters (keeping a short extension), and falls back to
  `file.<ext>` when nothing is left.
  """
  @spec sanitize_file_name(String.t(), String.t()) :: String.t()
  def sanitize_file_name(name, ext) when is_binary(name) do
    name =
      if String.valid?(name), do: name, else: :unicode.characters_to_binary(name, :latin1)

    name
    |> String.split(["/", "\\"])
    |> List.last()
    |> String.replace(~r/\p{Cc}/u, "")
    |> String.trim()
    |> cap_length()
    |> case do
      empty when empty in ["", ".", ".."] -> "file." <> ext
      name -> name
    end
  end

  # -- private -------------------------------------------------------------------------

  defp uploads_dir, do: Application.fetch_env!(:wedding_planner, :uploads_dir)

  defp check_size(path) do
    case File.stat(path) do
      {:ok, %File.Stat{type: :regular, size: 0}} -> {:error, :empty}
      {:ok, %File.Stat{type: :regular, size: size}} when size > @max_bytes -> {:error, :too_large}
      {:ok, %File.Stat{type: :regular}} -> :ok
      {:ok, %File.Stat{type: :directory}} -> {:error, :eisdir}
      {:ok, %File.Stat{}} -> {:error, :einval}
      {:error, reason} -> {:error, reason}
    end
  end

  defp sniff_file(path) do
    case File.open(path, [:read, :binary], &IO.binread(&1, @sniff_bytes)) do
      {:ok, prefix} when is_binary(prefix) ->
        case sniff(prefix) do
          {:ok, content_type, ext} -> {:ok, content_type, ext}
          :error -> {:error, :unsupported_type}
        end

      {:ok, _eof_or_error} ->
        {:error, :unsupported_type}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp new_key, do: 16 |> :crypto.strong_rand_bytes() |> Base.url_encode64(padding: false)

  # Copies at most `@max_bytes + 1` bytes, so the size is re-checked on what was actually
  # copied (the source could have changed since `check_size/1`), then renames the `.part`
  # into place. Any failure removes the `.part`; nothing is left under the final name.
  defp copy_into_place(source, destination) do
    part = destination <> ".part"

    with :ok <- File.mkdir_p(Path.dirname(destination)),
         {:ok, bytes} <- File.copy(source, part, @max_bytes + 1),
         :ok <- check_copied(bytes),
         :ok <- File.rename(part, destination) do
      {:ok, bytes}
    else
      {:error, reason} ->
        _ = File.rm(part)
        {:error, reason}
    end
  end

  defp check_copied(0), do: {:error, :empty}
  defp check_copied(bytes) when bytes > @max_bytes, do: {:error, :too_large}
  defp check_copied(_bytes), do: :ok

  defp cap_length(name) do
    if String.length(name) <= @file_name_max do
      name
    else
      ext = Path.extname(name)

      if ext != "" and String.length(ext) <= 10 do
        String.slice(name, 0, @file_name_max - String.length(ext)) <> ext
      else
        String.slice(name, 0, @file_name_max)
      end
    end
  end
end
