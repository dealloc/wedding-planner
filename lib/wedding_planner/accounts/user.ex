defmodule WeddingPlanner.Accounts.User do
  @moduledoc """
  A person who can log into the app (`docs/03-domain-model.md`).

  A user is nothing more than a display name plus the passkeys it owns (AUTH-02).
  Exactly two users exist in practice, but the count MUST NOT be hard-coded anywhere
  (`docs/03-domain-model.md`). There is no deletion or deactivation of users
  in v1 beyond this changeset, which is used at bootstrap (AUTH-03), when a user
  invitation link (AUTH-05) is redeemed and when a user edits their own name (AUTH-12).
  """
  use Ecto.Schema

  import Ecto.Changeset

  @type t :: %__MODULE__{}

  schema "users" do
    field :display_name, :string

    timestamps(type: :utc_datetime)
  end

  @doc """
  Changeset for creating a user (bootstrap setup, AUTH-03, or a redeemed user-invitation
  link, AUTH-05).
  """
  def changeset(user, attrs) do
    user
    |> cast(attrs, [:display_name])
    |> validate_required([:display_name])
    |> validate_length(:display_name, min: 1, max: 100)
  end
end
