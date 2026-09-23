defmodule WeddingPlanner.Repo.Migrations.CreateReferences do
  use Ecto.Migration

  # `docs/04-cross-cutting.md` XC-20 through XC-24; `DR-28`, `DR-29`, `DR-30`.
  #
  # * **No owner columns yet (`DR-28`).** A reference belongs to an offer or an invoice
  #   (XC-20), but neither table exists yet: offers arrive with slice C2 (W8), invoices
  #   with B2 (W10). Inventing their schemas here would be drift, and a placeholder owner
  #   column would have to be rebuilt later (SQLite cannot drop or retype a column
  #   without a table rebuild). So this table is owner-agnostic and
  #   `WeddingPlanner.References.Owner` is the attach point: C2 adds `offer_id`
  #   (`ALTER TABLE ADD COLUMN`, FK `on_delete: :restrict`), B2 adds `invoice_id` with a
  #   column CHECK "exactly one of `offer_id`/`invoice_id`". Until then nothing in the
  #   app may write rows here outside tests (an ownerless row would break B2's CHECK).
  # * **One row shape per kind (XC-20).** A `file` row carries the stored file's fields
  #   and no URL; a `url` row the reverse. Enforced as a column CHECK on `kind` (it spans
  #   the other columns, which SQLite accepts in a column constraint) — never
  #   `create constraint/3`, which SQLite does not support. It also pins `kind` to the
  #   two values the schema's `Ecto.Enum` knows.
  # * `content_type` is limited to the four sniffed types and `byte_size` to
  #   1..10 485 760 (10 MiB, `DR-29`) — backstops to `WeddingPlanner.References.Storage`,
  #   which decides both from the file's bytes, never the client's word.
  # * `file_key` is the random 22-character on-disk name (`DR-29`); the unique index is a
  #   backstop against two rows ever pointing at the same file (deleting one would
  #   silently delete the other's file). `file_name` is the original name, kept only for
  #   the download name — it is never part of a path.
  def change do
    create table(:references) do
      add :label, :string, null: false

      add :kind, :string,
        null: false,
        check: %{
          name: "references_kind_shape",
          expr: """
          (kind = 'file' AND file_key IS NOT NULL AND file_name IS NOT NULL
            AND content_type IS NOT NULL AND byte_size IS NOT NULL AND url IS NULL)
          OR (kind = 'url' AND url IS NOT NULL AND file_key IS NULL AND file_name IS NULL
            AND content_type IS NULL AND byte_size IS NULL)
          """
        }

      add :url, :string
      add :file_key, :string
      add :file_name, :string

      add :content_type, :string,
        check: %{
          name: "references_content_type_allowed",
          expr:
            "content_type IS NULL OR content_type IN " <>
              "('application/pdf', 'image/png', 'image/jpeg', 'image/webp')"
        }

      add :byte_size, :integer,
        check: %{
          name: "references_byte_size_range",
          expr: "byte_size IS NULL OR (byte_size >= 1 AND byte_size <= 10485760)"
        }

      timestamps(type: :utc_datetime)
    end

    create unique_index(:references, [:file_key])
  end
end
