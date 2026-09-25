defmodule WeddingPlanner.Transfer.SchemaVersion do
  @moduledoc """
  The data version an export is stamped with and an import is checked against
  (`DR-93` (1), (4)): the highest applied migration version.

  Two installations at the same version have the same tables and columns, so a file moves
  between them losslessly. A file from any other version is refused before a single row is
  read (`WeddingPlanner.Transfer.Document.parse/1`), with a message saying which side to
  update.

  It is read with `SELECT MAX(version) FROM schema_migrations` rather than
  `Ecto.Migrator.migrations/1`: the migrator also reads the migration files from `priv/`
  and first runs a `CREATE TABLE IF NOT EXISTS schema_migrations`, and this function is
  called inside the import's write transaction (`DR-98`), where only a plain read belongs.
  """

  alias WeddingPlanner.Repo

  @doc "The highest applied migration version, e.g. `20260924124144`."
  @spec current() :: pos_integer()
  def current do
    %{rows: [[version]]} = Repo.query!("SELECT MAX(version) FROM schema_migrations")
    version
  end
end
