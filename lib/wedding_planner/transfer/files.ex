defmodule WeddingPlanner.Transfer.Files do
  @moduledoc """
  The data transfer's own directory (`DR-97`): the stashed upload and the safety copies.
  Internal to `WeddingPlanner.Transfer`; the web layer only ever goes through that façade.

  `:transfer_dir` is read at call time (`Application.fetch_env!/2`, like
  `WeddingPlanner.References.Storage` reads `:uploads_dir`): `TRANSFER_PATH` (default
  `/data/transfer`, a sibling of the uploads dir on the volume) in prod,
  `tmp/transfer/{dev,test}` in dev and test. It is never under `priv/static` and never
  synced to the backup bucket. Its two subdirectories are created on demand:

    * `incoming/` holds an uploaded import file under a random token
      (`<token>.json`, the token being 24 random bytes as url-safe base64 without padding,
      32 characters), so the LiveView holds a token instead of 50 MB. It is removed after
      the import or on cancel, and every stash sweeps entries older than one hour.
    * `safety-copies/` holds the export written just before each import
      (`wedding-planner-before-import-dd-mm-yyyy-hhmm.json` in the importer's zone, `-2`,
      `-3`… on a same-minute clash). Safety copies are kept until someone deletes them by
      hand.

  Every write is `.part` plus rename (the `DR-29` atomic-write rule), so a crash never
  leaves a truncated file under a real name. A name coming back from outside (a token, a
  safety-copy name) is validated by regex **before** it is joined to a path, so nothing
  here can reach outside its directory.
  """

  require Logger

  @token_pattern ~r/\A[A-Za-z0-9_-]{32}\z/
  @safety_copy_pattern ~r/\Awedding-planner-before-import-(\d{2})-(\d{2})-(\d{4})-(\d{2})(\d{2})(?:-(\d+))?\.json\z/
  @stash_max_age_seconds 3600

  @doc "The regex a safety-copy name must match (`DR-97`)."
  @spec safety_copy_pattern() :: Regex.t()
  def safety_copy_pattern, do: @safety_copy_pattern

  @doc "Whether `token` has the shape `stash/2` hands out."
  @spec valid_token?(term()) :: boolean()
  def valid_token?(token), do: is_binary(token) and Regex.match?(@token_pattern, token)

  # -- incoming/ ---------------------------------------------------------------------------

  @doc """
  Copies `source` (never moves it: the LiveView owns its temp file) into `incoming/`
  under a fresh token, `.part` plus rename. At most `max_bytes + 1` bytes are copied, so a
  file that grew after the caller's size check is still refused (`:too_large`). Sweeps
  stale stashes first.
  """
  @spec stash(Path.t(), pos_integer()) :: {:ok, String.t()} | {:error, :too_large | File.posix()}
  def stash(source, max_bytes) do
    sweep_incoming()
    token = 24 |> :crypto.strong_rand_bytes() |> Base.url_encode64(padding: false)
    destination = stash_path!(token)
    part = destination <> ".part"

    with :ok <- File.mkdir_p(incoming_dir()),
         {:ok, copied} <- File.copy(source, part, max_bytes + 1),
         :ok <- if(copied > max_bytes, do: {:error, :too_large}, else: :ok),
         :ok <- File.rename(part, destination) do
      {:ok, token}
    else
      {:error, reason} ->
        _ = File.rm(part)
        {:error, reason}
    end
  end

  @doc "The stashed file for `token`, or `:error` when the token is malformed or gone."
  @spec read_stash(term()) :: {:ok, binary()} | :error
  def read_stash(token) do
    if valid_token?(token) do
      case File.read(stash_path!(token)) do
        {:ok, binary} -> {:ok, binary}
        {:error, _reason} -> :error
      end
    else
      :error
    end
  end

  @doc "Removes the stash for `token`; a missing file or a malformed token is fine."
  @spec discard(term()) :: :ok
  def discard(token) do
    if valid_token?(token), do: _ = File.rm(stash_path!(token))
    :ok
  end

  defp stash_path!(token) do
    true = valid_token?(token)
    Path.join(incoming_dir(), token <> ".json")
  end

  # Removes every entry of incoming/ (stashes and stray .part files) last modified more
  # than an hour ago. Best effort: a failure is logged, never raised.
  defp sweep_incoming do
    dir = incoming_dir()
    cutoff = System.os_time(:second) - @stash_max_age_seconds

    case File.ls(dir) do
      {:ok, names} ->
        for name <- names,
            path = Path.join(dir, name),
            match?(
              {:ok, %File.Stat{type: :regular, mtime: mtime}} when mtime < cutoff,
              File.stat(path, time: :posix)
            ) do
          case File.rm(path) do
            :ok -> :ok
            {:error, reason} -> Logger.warning("transfer: could not sweep #{path}: #{reason}")
          end
        end

        :ok

      {:error, _reason} ->
        :ok
    end
  end

  # -- safety-copies/ ----------------------------------------------------------------------

  @doc """
  Writes `iodata` as a new safety copy named for `now` in `time_zone`, `.part` plus
  rename, picking the first free name (`…-1405.json`, `…-1405-2.json`, …). Returns the
  name and the full path.
  """
  @spec write_safety_copy(iodata(), DateTime.t(), String.t()) ::
          {:ok, %{name: String.t(), path: Path.t()}} | {:error, File.posix()}
  def write_safety_copy(iodata, now, time_zone) do
    dir = safety_copies_dir()
    stamp = now |> DateTime.shift_zone!(time_zone) |> Calendar.strftime("%d-%m-%Y-%H%M")
    base = "wedding-planner-before-import-" <> stamp

    with :ok <- File.mkdir_p(dir) do
      name = free_name(dir, base, 1)
      path = Path.join(dir, name)
      part = path <> ".part"

      case File.write(part, iodata) do
        :ok ->
          case File.rename(part, path) do
            :ok ->
              {:ok, %{name: name, path: path}}

            {:error, reason} ->
              _ = File.rm(part)
              {:error, reason}
          end

        {:error, reason} ->
          _ = File.rm(part)
          {:error, reason}
      end
    end
  end

  defp free_name(dir, base, n) do
    name = if n == 1, do: base <> ".json", else: "#{base}-#{n}.json"

    if File.exists?(Path.join(dir, name)) or File.exists?(Path.join(dir, name <> ".part")),
      do: free_name(dir, base, n + 1),
      else: name
  end

  @doc "Removes a safety copy by full path (used when the import rolls back)."
  @spec remove_safety_copy(Path.t()) :: :ok
  def remove_safety_copy(path) do
    case File.rm(path) do
      :ok -> :ok
      {:error, :enoent} -> :ok
      {:error, reason} -> Logger.warning("transfer: could not remove #{path}: #{reason}")
    end

    :ok
  end

  @doc """
  The safety copies, newest first: regular files in `safety-copies/` whose name matches
  `safety_copy_pattern/0`, ordered by modification time, then by the moment in the name
  and its clash suffix (two copies written in the same second).
  """
  @spec list_safety_copies() :: [
          %{name: String.t(), byte_size: non_neg_integer(), saved_at: DateTime.t()}
        ]
  def list_safety_copies do
    dir = safety_copies_dir()

    case File.ls(dir) do
      {:ok, names} ->
        names
        |> Enum.flat_map(fn name ->
          with [_ | _] = captures <- Regex.run(@safety_copy_pattern, name),
               {:ok, %File.Stat{type: :regular, size: size, mtime: mtime}} <-
                 File.stat(Path.join(dir, name), time: :posix) do
            [
              {%{name: name, byte_size: size, saved_at: DateTime.from_unix!(mtime)}, mtime,
               sort_key(captures)}
            ]
          else
            _ -> []
          end
        end)
        |> Enum.sort_by(fn {_copy, mtime, key} -> {mtime, key} end, :desc)
        |> Enum.map(fn {copy, _mtime, _key} -> copy end)

      {:error, _reason} ->
        []
    end
  end

  # {yyyy, mm, dd, hh, mi, suffix} as integers, so ties on mtime order by the name's moment
  # and then by the clash suffix (no suffix = 1).
  defp sort_key([_name, dd, mm, yyyy, hh, mi | suffix]) do
    n =
      case suffix do
        [s] when s != "" -> String.to_integer(s)
        _ -> 1
      end

    Enum.map([yyyy, mm, dd, hh, mi], &String.to_integer/1) ++ [n]
  end

  @doc """
  The full path of the safety copy `name`, only when `name` matches
  `safety_copy_pattern/0` **and** is a regular file in `safety-copies/`. The name is
  checked before it is joined to anything, so there is no traversal (`DR-97`).
  """
  @spec safety_copy_path(term()) :: {:ok, Path.t()} | :error
  def safety_copy_path(name) when is_binary(name) do
    if Regex.match?(@safety_copy_pattern, name) do
      path = Path.join(safety_copies_dir(), name)
      if File.regular?(path), do: {:ok, path}, else: :error
    else
      :error
    end
  end

  def safety_copy_path(_name), do: :error

  # -- dirs --------------------------------------------------------------------------------

  defp transfer_dir, do: Application.fetch_env!(:wedding_planner, :transfer_dir)
  defp incoming_dir, do: Path.join(transfer_dir(), "incoming")
  defp safety_copies_dir, do: Path.join(transfer_dir(), "safety-copies")
end
