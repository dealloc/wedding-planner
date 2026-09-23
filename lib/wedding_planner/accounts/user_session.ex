defmodule WeddingPlanner.Accounts.UserSession do
  @moduledoc """
  A signed-in browser (`AUTH-01`, `AUTH-10`). Every field is set programmatically by
  `WeddingPlanner.Accounts.Sessions` — never cast from user input — so this schema
  exposes narrow, purpose-built changesets rather than a general-purpose `cast/3` over
  every field.

  See `priv/repo/migrations/*_create_user_sessions.exs` for the field-by-field rationale
  (why `token` is stored raw, the `on_delete` choice for `user_id` and `passkey_id`).
  """
  use Ecto.Schema

  import Ecto.Changeset

  alias WeddingPlanner.Accounts.Passkey
  alias WeddingPlanner.Accounts.User

  @type t :: %__MODULE__{}

  schema "user_sessions" do
    field :token, :binary
    field :last_used_at, :utc_datetime

    belongs_to :user, User
    belongs_to :passkey, Passkey

    timestamps(type: :utc_datetime, updated_at: false)
  end

  @doc """
  Changeset for a freshly established session. `user_id` and `passkey_id` are set on the
  struct by the caller (e.g. `%__MODULE__{user_id: user.id, passkey_id: passkey_id}`),
  not cast here.
  """
  def create_changeset(session, attrs) do
    session
    |> cast(attrs, [:token, :last_used_at])
    |> validate_required([:token, :last_used_at])
    |> unique_constraint(:token)
  end

  @doc "AUTH-10: extends the sliding expiry window to `now`."
  def touch_changeset(session, now) do
    change(session, last_used_at: now)
  end
end
