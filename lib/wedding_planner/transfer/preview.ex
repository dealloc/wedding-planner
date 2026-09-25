defmodule WeddingPlanner.Transfer.Preview do
  @moduledoc """
  What an import would do, shown before the user confirms it (`DR-93` (5)): per kind of
  data, the count in the file against the count here now; when and where the file was
  exported and its data version; the uploaded files it carries against the ones here now;
  and how its users will be matched (`WeddingPlanner.Transfer.UserRemap`). Reads only.

  `counts` lists the registry entries with `preview?: true`
  (`WeddingPlanner.Transfer.Tables.transferred/0`) in registry order, so the
  `demo_seed_runs` bookkeeping table (`DR-79`) travels but is never shown. `files.here_now`
  counts the distinct file keys of the file references here now, the same unit as
  `files.in_file`. `missing_files` counts the file references whose file the source didn't
  have on disk when it exported.
  """

  import Ecto.Query

  alias WeddingPlanner.Accounts.Scope
  alias WeddingPlanner.References.Reference
  alias WeddingPlanner.Repo
  alias WeddingPlanner.Transfer.Document
  alias WeddingPlanner.Transfer.UserRemap

  @type t :: %{
          exported_at: DateTime.t(),
          source_host: String.t(),
          schema_version: pos_integer(),
          counts: [
            %{
              key: String.t(),
              label: String.t(),
              in_file: non_neg_integer(),
              here_now: non_neg_integer()
            }
          ],
          files: %{
            in_file: non_neg_integer(),
            in_file_bytes: non_neg_integer(),
            here_now: non_neg_integer()
          },
          users: [%{source_name: String.t(), target_name: String.t(), matched?: boolean()}],
          missing_files: non_neg_integer()
        }

  @doc "The preview of importing `document` as `scope`'s user."
  @spec build(Document.t(), Scope.t()) :: t()
  def build(%Document{meta: meta} = document, %Scope{} = scope) do
    in_file = Document.counts(document)

    %{
      exported_at: meta.exported_at,
      source_host: meta.source_host,
      schema_version: meta.schema_version,
      counts:
        for {%{preview?: true} = entry, _rows} <- document.tables do
          %{
            key: entry.key,
            label: entry.label,
            in_file: Map.fetch!(in_file, entry.key),
            here_now: Repo.aggregate(entry.schema, :count)
          }
        end,
      files: %{
        in_file: map_size(document.files),
        in_file_bytes:
          document.files |> Map.values() |> Enum.map(&byte_size(&1.bytes)) |> Enum.sum(),
        here_now:
          Repo.one(
            from(r in Reference,
              where: r.kind == :file,
              select: count(r.file_key, :distinct)
            )
          )
      },
      users: UserRemap.build(document, scope).preview,
      missing_files: length(meta.missing_files)
    }
  end
end
