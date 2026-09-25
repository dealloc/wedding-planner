defmodule WeddingPlanner.Transfer.Refusal do
  @moduledoc """
  Why a data transfer was refused (`DR-93` (4)). Nothing is ever written when one is
  returned.

  `message` is plain English, ready to show as is. `detail` is machine-readable and depends
  on the reason (for `:malformed`, `%{path: path, location: location}`, see
  `WeddingPlanner.Transfer.Document`; for `:schema_mismatch`, `%{file: v, app: v}`).

  ## Reasons

  Produced by the parser (`WeddingPlanner.Transfer.Document.parse/1`):

    * `:malformed`: the file is damaged or not valid JSON; the message names the location
      (`offers[3].status`).
    * `:wrong_format`: valid JSON, but not a wedding planner export.
    * `:unsupported_format_version`: a later file format than this app reads.
    * `:schema_mismatch`: exported from an app at a different data version
      (`WeddingPlanner.Transfer.SchemaVersion`); the message says which side to update.
    * `:too_large`: over the import size limit (`DR-97`).

  Reserved for the import itself (task 100, `DR-94`, `DR-97`, `DR-98`):

    * `:expired`: the stashed upload is gone (swept after an hour, or already used).
    * `:inconsistent`: the rows break a database constraint or foreign key; the message
      names the table and row.
    * `:file_conflict`: an embedded file's key is already on disk with different bytes.
    * `:storage`: a file could not be written or read on this installation.
    * `:busy`: the other user was saving at that moment.
  """

  @enforce_keys [:reason, :message]
  defstruct [:reason, :message, detail: nil]

  @type reason ::
          :malformed
          | :wrong_format
          | :unsupported_format_version
          | :schema_mismatch
          | :too_large
          | :expired
          | :inconsistent
          | :file_conflict
          | :storage
          | :busy

  @type t :: %__MODULE__{reason: reason(), message: String.t(), detail: term()}
end
