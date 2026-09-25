defmodule WeddingPlanner.Transfer.Document do
  @moduledoc """
  The data-transfer file: one JSON document carrying every transferred row and every
  uploaded file (`DR-93`, `DR-96`). `encode/1` writes it deterministically; `parse/1` reads
  it back into typed rows, strictly, refusing anything wrong with a located message.

  ## Layout

      {
        "format": "wedding-planner-transfer",
        "format_version": 1,
        "meta": {"schema_version": 20260924124144, "exported_at": "2026-09-25T12:05:00Z",
                 "source_host": "localhost:4000", "missing_files": []},
        "users": [{"id": 1, "display_name": "Wannes"}],
        "tables": {"settings": [{"id": 1, "overall_budget": {"amount": "45000", "currency": "EUR"}, …}], …},
        "files": [{"file_key": "<22 chars>", "content_type": "application/pdf", "byte_size": 1234,
                   "sha256": "<lowercase hex>", "data_base64": "<standard base64, padded>"}]
      }

  `tables` holds every key of `WeddingPlanner.Transfer.Tables.transferred/0` in registry
  order, each a list of rows by id ascending, each row keyed by field name in
  `__schema__(:fields)` order and encoded by `WeddingPlanner.Transfer.Codec`. `users` is the
  remap list only (`DR-93` (2)). `files` holds one entry per file reference whose file was
  on disk, sorted by key; the keys of those that were absent are in `meta.missing_files`, so
  a damaged source can still be exported and re-imported as is.

  `encode/1` takes that document as a plain, string-keyed JSON term (what
  `WeddingPlanner.Transfer.Export.document/1` returns, or what `Jason.decode!/1` gives back)
  and writes it pretty-printed with every object's keys in the fixed order above
  (`Jason.OrderedObject`): known keys first in layout / field order, any other keys after
  them, sorted. Same data, same bytes. Dates and datetimes are ISO 8601 (`NFR-20`, `NFR-21`):
  the file is machine to machine, so the `dd/mm/yyyy` display rule doesn't apply to it.

  ## Parsing (`DR-93` (4), `DR-96`)

  `parse/1` checks, in this order, and returns the first refusal
  (`WeddingPlanner.Transfer.Refusal`):

    1. size over `max_bytes/0` (50 MB, `DR-97`): `:too_large`;
    2. not JSON, or the top level isn't an object: `:malformed`;
    3. `format` isn't `"wedding-planner-transfer"`: `:wrong_format`;
    4. `format_version` above 1: `:unsupported_format_version` (below 1, or not a whole
       number: `:malformed`);
    5. `meta.schema_version` isn't `WeddingPlanner.Transfer.SchemaVersion.current/0`:
       `:schema_mismatch`, saying which side to update. It is checked **before** any row is
       read, so a file from another version is never reported as a damaged row;
    6. the top-level keys, `meta` and `users` have exactly their keys and types;
    7. `tables` has exactly the registry's tables, each row exactly its schema's fields,
       every value decodes (`Codec.decode/3`), ids are unique per table;
    8. every user reference (`Tables.user_references/0`) is `null` or an id in `users`;
    9. every file entry has its five keys and a valid key (22 characters of
       `[A-Za-z0-9_-]`, `DR-29`); its base64 decodes; `byte_size` and `sha256` match the
       bytes; the bytes sniff (`Storage.sniff/1`) as its `content_type` (`XC-21`); it is 1
       byte to `Storage.max_bytes/0`; keys are unique; every file reference has an entry or
       its key in `meta.missing_files`; every entry is used by a file reference with the
       same content type.

  ## Located messages

  Every `:malformed` message reads *"This file is damaged: `<location>` `<problem>`."*, e.g.
  *"This file is damaged: offers[3].status has an unknown value \\"maybe\\"."*,
  *"… tables.events is missing."*, *"… files[2] doesn't match its checksum."* A row is
  located as `<table>[i].<field>`, anything else by its path from the top
  (`meta.exported_at`, `users[0].id`, `files[2].file_key`). **`[i]` is the 0-based index in
  the file's list.** The refusal's `detail` is `%{path: path, location: location}`, where
  `path` is the machine-readable form (`["tables", "offers", 3, "status"]`).
  """

  alias WeddingPlanner.References.Storage
  alias WeddingPlanner.Transfer.Codec
  alias WeddingPlanner.Transfer.Refusal
  alias WeddingPlanner.Transfer.SchemaVersion
  alias WeddingPlanner.Transfer.Tables

  @format "wedding-planner-transfer"
  @format_version 1
  # DR-97: task 100's `WeddingPlanner.Transfer.max_upload_bytes/0` MUST equal this; a
  # caller with its own limit passes `max_bytes:` to `parse/2`.
  @max_bytes 50_000_000
  @key_pattern ~r/\A[A-Za-z0-9_-]{22}\z/

  @top_keys ~w(format format_version meta users tables files)
  @meta_keys ~w(schema_version exported_at source_host missing_files)
  @user_keys ~w(id display_name)
  @file_keys ~w(file_key content_type byte_size sha256 data_base64)

  defstruct [:meta, :users, :tables, :files]

  @type row :: %{atom() => term()}

  @type t :: %__MODULE__{
          meta: %{
            format_version: 1,
            schema_version: pos_integer(),
            exported_at: DateTime.t(),
            source_host: String.t(),
            missing_files: [String.t()]
          },
          users: [%{id: pos_integer(), display_name: String.t()}],
          tables: [{Tables.entry(), [row()]}],
          files: %{String.t() => %{content_type: String.t(), bytes: binary()}}
        }

  @doc ~s(The `format` marker: `"#{@format}"`.)
  @spec format() :: String.t()
  def format, do: @format

  @doc "The file format version this app writes and reads: #{@format_version}."
  @spec format_version() :: pos_integer()
  def format_version, do: @format_version

  @doc "The largest file `parse/1` accepts: 50 000 000 bytes (`DR-97`)."
  @spec max_bytes() :: pos_integer()
  def max_bytes, do: @max_bytes

  # -- encode ------------------------------------------------------------------------------

  @doc """
  Writes the document (a plain, string-keyed JSON term, see the moduledoc) as
  pretty-printed JSON with every object's keys in the fixed layout order.
  """
  @spec encode(map()) :: iodata()
  def encode(document) when is_map(document) do
    document |> canonical_top() |> Jason.encode_to_iodata!(pretty: true)
  end

  defp canonical_top(document) do
    ordered(document, @top_keys, fn
      "meta", meta -> ordered(meta, @meta_keys, &generic/2)
      "users", users -> each_ordered(users, @user_keys)
      "tables", tables -> canonical_tables(tables)
      "files", files -> each_ordered(files, @file_keys)
      _key, value -> generic(nil, value)
    end)
  end

  defp canonical_tables(tables) when is_map(tables) do
    fields_by_key =
      Map.new(Tables.transferred(), fn %{key: key, schema: schema} ->
        {key, Enum.map(schema.__schema__(:fields), &Atom.to_string/1)}
      end)

    ordered(tables, Enum.map(Tables.transferred(), & &1.key), fn key, rows ->
      case fields_by_key do
        %{^key => fields} -> each_ordered(rows, fields)
        _ -> generic(nil, rows)
      end
    end)
  end

  defp canonical_tables(other), do: generic(nil, other)

  defp each_ordered(list, keys) when is_list(list),
    do: Enum.map(list, &ordered(&1, keys, fn _key, value -> generic(nil, value) end))

  defp each_ordered(other, _keys), do: generic(nil, other)

  # Known keys first, in the given order; any other keys after them, sorted.
  defp ordered(%{} = map, known, value_fun) when not is_struct(map) do
    present = Enum.filter(known, &Map.has_key?(map, &1))
    others = map |> Map.keys() |> Enum.reject(&(&1 in known)) |> Enum.sort()

    Jason.OrderedObject.new(for key <- present ++ others, do: {key, value_fun.(key, map[key])})
  end

  defp ordered(other, _known, _value_fun), do: generic(nil, other)

  defp generic(_key, %{} = map) when not is_struct(map), do: ordered(map, [], &generic/2)
  defp generic(_key, list) when is_list(list), do: Enum.map(list, &generic(nil, &1))
  defp generic(_key, value), do: value

  # -- parse -------------------------------------------------------------------------------

  @doc """
  Parses and validates an export (see the moduledoc for the checks and their order).

  Options: `max_bytes:` (default `max_bytes/0`).
  """
  @spec parse(binary(), keyword()) :: {:ok, t()} | {:error, Refusal.t()}
  def parse(binary, opts \\ []) when is_binary(binary) do
    max_bytes = Keyword.get(opts, :max_bytes, @max_bytes)

    if byte_size(binary) > max_bytes do
      {:error,
       %Refusal{
         reason: :too_large,
         message: "This file is larger than the #{div(max_bytes, 1_000_000)} MB import limit.",
         detail: %{byte_size: byte_size(binary), max_bytes: max_bytes}
       }}
    else
      try do
        {:ok, do_parse(binary)}
      catch
        {:transfer_refusal, %Refusal{} = refusal} -> {:error, refusal}
      end
    end
  end

  @doc "The number of rows per table key, for every registry table."
  @spec counts(t()) :: %{String.t() => non_neg_integer()}
  def counts(%__MODULE__{tables: tables}) do
    Map.new(tables, fn {%{key: key}, rows} -> {key, length(rows)} end)
  end

  defp do_parse(binary) do
    json = decode_json!(binary)
    check_format!(json)
    check_format_version!(json)
    schema_version = check_schema_version!(json)
    check_keys!(json, @top_keys, [])

    meta = decode_meta!(json["meta"], schema_version)
    users = decode_users!(json["users"])
    tables = decode_tables!(json["tables"])
    check_user_references!(tables, users)
    files = decode_files!(json["files"], tables, meta.missing_files)

    %__MODULE__{meta: meta, users: users, tables: tables, files: files}
  end

  # 2.
  defp decode_json!(binary) do
    case Jason.decode(binary) do
      {:ok, %{} = json} ->
        json

      _ ->
        refuse!(:malformed, "This file can't be read: it isn't valid JSON.", %{path: []})
    end
  end

  # 3.
  defp check_format!(%{"format" => @format}), do: :ok

  defp check_format!(_json),
    do: refuse!(:wrong_format, "This file isn't a wedding planner export.", nil)

  # 4.
  defp check_format_version!(%{"format_version" => @format_version}), do: :ok

  defp check_format_version!(%{"format_version" => version})
       when is_integer(version) and version > @format_version do
    refuse!(
      :unsupported_format_version,
      "This export uses file format #{version}, which this version of the app can't read. " <>
        "Update this app first.",
      %{file: version, app: @format_version}
    )
  end

  defp check_format_version!(%{"format_version" => _}),
    do: damaged!(["format_version"], "must be #{@format_version}")

  defp check_format_version!(_json), do: damaged!(["format_version"], "is missing")

  # 5.
  defp check_schema_version!(json) do
    meta = object!(json, "meta", ["meta"])

    version =
      case meta do
        %{"schema_version" => version} when is_integer(version) -> version
        %{"schema_version" => _} -> damaged!(["meta", "schema_version"], "must be a whole number")
        _ -> damaged!(["meta", "schema_version"], "is missing")
      end

    app = SchemaVersion.current()

    cond do
      version == app ->
        version

      version < app ->
        refuse!(
          :schema_mismatch,
          "This file comes from an older version of the app (data version #{version}; " <>
            "this app is at #{app}). Update the app you exported from to the same version, " <>
            "export again, then import.",
          %{file: version, app: app}
        )

      true ->
        refuse!(
          :schema_mismatch,
          "This file comes from a newer version of the app (data version #{version}; " <>
            "this app is at #{app}). Update this app first, then import again.",
          %{file: version, app: app}
        )
    end
  end

  # 6.
  defp decode_meta!(meta, schema_version) do
    check_keys!(meta, @meta_keys, ["meta"])

    %{
      format_version: @format_version,
      schema_version: schema_version,
      exported_at: decode_exported_at!(meta["exported_at"]),
      source_host: decode_source_host!(meta["source_host"]),
      missing_files: decode_missing_files!(meta["missing_files"])
    }
  end

  defp decode_exported_at!(value) do
    case Codec.decode_kind(:utc_datetime, value) do
      {:ok, %DateTime{} = exported_at} -> exported_at
      {:ok, nil} -> damaged!(["meta", "exported_at"], "must be a UTC time, not null")
      {:error, phrase} -> damaged!(["meta", "exported_at"], phrase)
    end
  end

  defp decode_source_host!(host) when is_binary(host) and host != "", do: host
  defp decode_source_host!(_host), do: damaged!(["meta", "source_host"], "must be non-empty text")

  defp decode_missing_files!(keys) do
    keys = list!(keys, ["meta", "missing_files"])

    keys
    |> Enum.with_index()
    |> Enum.each(fn {key, index} ->
      unless valid_key?(key),
        do: damaged!(["meta", "missing_files", index], "isn't a valid file key")
    end)

    keys
  end

  defp decode_users!(users) do
    users
    |> list!(["users"])
    |> Enum.with_index()
    |> Enum.reduce({[], %{}}, fn {user, index}, {acc, seen} ->
      path = ["users", index]
      check_keys!(user, @user_keys, path)

      id =
        case user["id"] do
          id when is_integer(id) -> id
          _ -> damaged!(path ++ ["id"], "must be a whole number")
        end

      name =
        case user["display_name"] do
          name when is_binary(name) -> name
          _ -> damaged!(path ++ ["display_name"], "must be text")
        end

      if Map.has_key?(seen, id) do
        damaged!(path ++ ["id"], "repeats id #{id} (also #{location(["users", seen[id]])})")
      end

      {[%{id: id, display_name: name} | acc], Map.put(seen, id, index)}
    end)
    |> elem(0)
    |> Enum.reverse()
  end

  # 7.
  defp decode_tables!(tables) do
    tables = object!(%{"tables" => tables}, "tables", ["tables"])
    registry = Tables.transferred()
    known = Enum.map(registry, & &1.key)

    for key <- known, not Map.has_key?(tables, key), do: damaged!(["tables", key], "is missing")

    for key <- tables |> Map.keys() |> Enum.sort(),
        key not in known,
        do: damaged!(["tables", key], "is not part of the format")

    for %{key: key} = entry <- registry do
      {entry, decode_rows!(entry, tables[key])}
    end
  end

  defp decode_rows!(%{key: key, schema: schema}, rows) do
    fields = schema.__schema__(:fields)
    field_names = Enum.map(fields, &Atom.to_string/1)

    rows
    |> list!(["tables", key])
    |> Enum.with_index()
    |> Enum.reduce({[], %{}}, fn {row, index}, {acc, seen} ->
      path = ["tables", key, index]
      check_keys!(row, field_names, path)

      decoded =
        Map.new(fields, fn field ->
          name = Atom.to_string(field)

          case Codec.decode(schema, field, row[name]) do
            {:ok, value} -> {field, value}
            {:error, phrase} -> damaged!(path ++ [name], phrase)
          end
        end)

      id = decoded.id

      cond do
        is_nil(id) ->
          damaged!(path ++ ["id"], "must be a whole number, not null")

        Map.has_key?(seen, id) ->
          damaged!(
            path ++ ["id"],
            "repeats id #{id} (also #{location(["tables", key, seen[id]])})"
          )

        true ->
          {[decoded | acc], Map.put(seen, id, index)}
      end
    end)
    |> elem(0)
    |> Enum.reverse()
  end

  # 8.
  defp check_user_references!(tables, users) do
    user_ids = MapSet.new(users, & &1.id)

    for {schema, field} <- Tables.user_references(),
        {%{key: key, schema: ^schema}, rows} <- tables,
        {row, index} <- Enum.with_index(rows) do
      case Map.fetch!(row, field) do
        nil ->
          :ok

        user_id ->
          unless MapSet.member?(user_ids, user_id) do
            damaged!(
              ["tables", key, index, Atom.to_string(field)],
              "refers to user #{user_id}, who isn't in users"
            )
          end
      end
    end

    :ok
  end

  # 9.
  defp decode_files!(files, tables, missing_files) do
    entries =
      files
      |> list!(["files"])
      |> Enum.with_index()
      |> Enum.reduce({[], %{}}, fn {file, index}, {acc, seen} ->
        path = ["files", index]
        entry = decode_file!(file, path)

        if Map.has_key?(seen, entry.key) do
          damaged!(
            path ++ ["file_key"],
            "repeats file key #{inspect(entry.key)} (also #{location(["files", seen[entry.key]])})"
          )
        end

        {[Map.put(entry, :index, index) | acc], Map.put(seen, entry.key, index)}
      end)
      |> elem(0)
      |> Enum.reverse()

    by_key = Map.new(entries, &{&1.key, &1})
    missing = MapSet.new(missing_files)

    missing_files
    |> Enum.with_index()
    |> Enum.each(fn {key, index} ->
      if Map.has_key?(by_key, key) do
        damaged!(
          ["meta", "missing_files", index],
          "names a file that is in files (#{location(["files", by_key[key].index])})"
        )
      end
    end)

    {%{key: references_key}, references} =
      Enum.find(tables, fn {%{schema: schema}, _rows} ->
        schema == WeddingPlanner.References.Reference
      end)

    used =
      for {%{kind: :file} = reference, index} <- Enum.with_index(references),
          reduce: MapSet.new() do
        used ->
          path = ["tables", references_key, index]
          key = reference.file_key

          case by_key do
            %{^key => %{content_type: content_type}}
            when content_type == reference.content_type ->
              MapSet.put(used, key)

            %{^key => entry} ->
              damaged!(
                ["files", entry.index, "content_type"],
                "is #{inspect(entry.content_type)}, but #{location(path)} says " <>
                  inspect(reference.content_type)
              )

            _ ->
              if MapSet.member?(missing, key) do
                used
              else
                damaged!(
                  path ++ ["file_key"],
                  "refers to file #{inspect(key)}, which isn't in files or meta.missing_files"
                )
              end
          end
      end

    for entry <- entries, not MapSet.member?(used, entry.key) do
      damaged!(["files", entry.index], "isn't used by any file reference")
    end

    Map.new(entries, &{&1.key, %{content_type: &1.content_type, bytes: &1.bytes}})
  end

  defp decode_file!(file, path) do
    check_keys!(file, @file_keys, path)

    key = file["file_key"]
    unless valid_key?(key), do: damaged!(path ++ ["file_key"], "isn't a valid file key")

    content_type = file["content_type"]
    unless is_binary(content_type), do: damaged!(path ++ ["content_type"], "must be text")

    declared_size = file["byte_size"]

    unless is_integer(declared_size),
      do: damaged!(path ++ ["byte_size"], "must be a whole number")

    sha256 = file["sha256"]
    unless is_binary(sha256), do: damaged!(path ++ ["sha256"], "must be text")

    bytes =
      with data when is_binary(data) <- file["data_base64"],
           {:ok, bytes} <- Base.decode64(data) do
        bytes
      else
        _ -> damaged!(path ++ ["data_base64"], "isn't valid base64")
      end

    cond do
      byte_size(bytes) != declared_size ->
        damaged!(path, "doesn't match its byte size")

      :crypto.hash(:sha256, bytes) |> Base.encode16(case: :lower) != sha256 ->
        damaged!(path, "doesn't match its checksum")

      not match?({:ok, ^content_type, _ext}, Storage.sniff(bytes)) ->
        damaged!(path, "isn't the #{inspect(content_type)} file it claims to be")

      byte_size(bytes) > Storage.max_bytes() ->
        damaged!(path, "is larger than the #{Storage.max_bytes()}-byte upload limit")

      true ->
        %{key: key, content_type: content_type, bytes: bytes}
    end
  end

  # -- helpers -----------------------------------------------------------------------------

  defp valid_key?(key), do: is_binary(key) and Regex.match?(@key_pattern, key)

  defp object!(parent, key, path) do
    case parent do
      %{^key => %{} = object} -> object
      %{^key => _} -> damaged!(path, "must be an object")
      _ -> damaged!(path, "is missing")
    end
  end

  defp list!(list, _path) when is_list(list), do: list
  defp list!(_other, path), do: damaged!(path, "must be a list")

  # Exactly `keys`: the first missing one (in `keys` order), then the first unknown one
  # (sorted) is reported.
  defp check_keys!(%{} = object, keys, path) do
    for key <- keys, not Map.has_key?(object, key), do: damaged!(path ++ [key], "is missing")

    for key <- object |> Map.keys() |> Enum.sort(),
        key not in keys,
        do: damaged!(path ++ [key], "is not part of the format")

    :ok
  end

  defp check_keys!(_other, _keys, path), do: damaged!(path, "must be an object")

  defp damaged!(path, phrase) do
    location = location(path)

    refuse!(:malformed, "This file is damaged: #{location} #{phrase}.", %{
      path: path,
      location: location
    })
  end

  defp refuse!(reason, message, detail),
    do: throw({:transfer_refusal, %Refusal{reason: reason, message: message, detail: detail}})

  # ["tables", "offers", 3, "status"] → "offers[3].status"; ["tables", "events"] →
  # "tables.events"; ["files", 2] → "files[2]"; ["meta", "exported_at"] → "meta.exported_at".
  @doc false
  @spec location([String.t() | non_neg_integer()]) :: String.t()
  def location(["tables", table, index | rest]) when is_integer(index),
    do: location([table, index | rest])

  def location([]), do: "the file"

  def location([first | rest]) do
    Enum.reduce(rest, to_string(first), fn
      index, acc when is_integer(index) -> "#{acc}[#{index}]"
      key, acc -> "#{acc}.#{key}"
    end)
  end
end
