defmodule WeddingPlanner.Transfer.Export do
  @moduledoc """
  The one reader behind a data export (`DR-93` (1), `DR-96`): every transferred table
  from the database plus every uploaded file from disk, as the document
  `WeddingPlanner.Transfer.Document` describes.

  Rows are loaded per registry entry (`WeddingPlanner.Transfer.Tables.transferred/0`) by id
  ascending and encoded field by field with `WeddingPlanner.Transfer.Codec` (money as a
  decimal string plus currency, `NFR-10`, `DR-18`; dates and datetimes ISO 8601, `NFR-20`,
  `NFR-21`). `users` carries only `id` and `display_name`, for the import's remap
  (`DR-93` (2)); passkeys, sessions and enrollment links never leave the installation.
  `demo_seed_runs` travels with the data (`DR-79`).

  Each file reference's file is read with `File.read(Storage.path_for(reference))` and
  embedded (base64, sha256, byte size; `XC-21`). A file that is missing or unreadable does
  **not** fail the export: its key goes into `meta.missing_files` and a warning is logged.
  The export is also the import's safety copy, and it must never block an import.

  Everything here is a read: no transaction of its own, so it runs inside the import's
  write transaction and sees that transaction's state (`DR-98`). The web layer supplies
  `source_host`; this module never asks the Endpoint.
  """

  import Ecto.Query

  require Logger

  alias WeddingPlanner.Accounts.User
  alias WeddingPlanner.References.Reference
  alias WeddingPlanner.References.Storage
  alias WeddingPlanner.Repo
  alias WeddingPlanner.Transfer.Codec
  alias WeddingPlanner.Transfer.Document
  alias WeddingPlanner.Transfer.SchemaVersion
  alias WeddingPlanner.Transfer.Tables

  @doc """
  The document as a plain, string-keyed JSON term (see `WeddingPlanner.Transfer.Document`):
  exactly what `Jason.decode!/1` gives back from `build/1`'s output.

  Options: `source_host:` (required, e.g. `"localhost:4000"`), `now:` (the export moment,
  default `DateTime.utc_now(:second)`).
  """
  @spec document(keyword()) :: map()
  def document(opts) do
    source_host = Keyword.fetch!(opts, :source_host)

    now =
      opts
      |> Keyword.get_lazy(:now, fn -> DateTime.utc_now(:second) end)
      |> DateTime.shift_zone!("Etc/UTC")
      |> DateTime.truncate(:second)

    loaded = for entry <- Tables.transferred(), do: {entry, load_rows(entry.schema)}
    {files, missing_files} = load_files(loaded)

    %{
      "format" => Document.format(),
      "format_version" => Document.format_version(),
      "meta" => %{
        "schema_version" => SchemaVersion.current(),
        "exported_at" => DateTime.to_iso8601(now),
        "source_host" => source_host,
        "missing_files" => missing_files
      },
      "users" => load_users(),
      "tables" =>
        Map.new(loaded, fn {%{key: key, schema: schema}, rows} ->
          {key, Enum.map(rows, &encode_row(schema, &1))}
        end),
      "files" => files
    }
  end

  @doc "`document/1`, encoded (`WeddingPlanner.Transfer.Document.encode/1`)."
  @spec build(keyword()) :: iodata()
  def build(opts), do: opts |> document() |> Document.encode()

  defp load_rows(schema), do: Repo.all(from(s in schema, order_by: [asc: s.id]))

  defp load_users do
    Repo.all(
      from(u in User,
        order_by: [asc: u.id],
        select: %{"id" => u.id, "display_name" => u.display_name}
      )
    )
  end

  defp encode_row(schema, row) do
    Map.new(schema.__schema__(:fields), fn field ->
      {Atom.to_string(field), Codec.encode(schema, field, Map.fetch!(row, field))}
    end)
  end

  defp load_files(loaded) do
    {_entry, references} =
      Enum.find(loaded, fn {%{schema: schema}, _rows} -> schema == Reference end)

    references
    |> Enum.filter(&(&1.kind == :file))
    |> Enum.uniq_by(& &1.file_key)
    |> Enum.sort_by(& &1.file_key)
    |> Enum.reduce({[], []}, fn reference, {files, missing} ->
      path = Storage.path_for(reference)

      case File.read(path) do
        {:ok, bytes} ->
          {[file_entry(reference, bytes) | files], missing}

        {:error, reason} ->
          Logger.warning(
            "transfer export: file of reference #{reference.id} is unreadable " <>
              "(#{inspect(reason)}): #{path}; listed in meta.missing_files"
          )

          {files, [reference.file_key | missing]}
      end
    end)
    |> then(fn {files, missing} -> {Enum.reverse(files), Enum.reverse(missing)} end)
  end

  defp file_entry(reference, bytes) do
    %{
      "file_key" => reference.file_key,
      "content_type" => reference.content_type,
      "byte_size" => byte_size(bytes),
      "sha256" => :crypto.hash(:sha256, bytes) |> Base.encode16(case: :lower),
      "data_base64" => Base.encode64(bytes)
    }
  end
end
