defmodule WeddingPlanner.Accounts.Sessions do
  @moduledoc """
  Server-side sessions behind `AUTH-01`'s gate: `AUTH-10`'s sliding 30-day expiry, and
  which passkey (if any — `AUTH-02` means there's always one at creation, but the field
  is nullable so a session survives its passkey being removed later, see the migration)
  opened each one.

  This module is plain Elixir, like `WeddingPlanner.Accounts.WebAuthn`: no `Plug.Conn`,
  no socket. `WeddingPlannerWeb.Live.LoginLive` calls `create_session/3` once a ceremony
  verifies; `WeddingPlannerWeb.UserAuth` calls `fetch_by_token/2` on every authenticated
  request (extending the window) and `delete_session/1` on sign-out.

  ## Sliding expiry (`AUTH-10`)

  A session is valid until `last_used_at + #{30} days`. Nothing stores a separately
  computed `expires_at` that would need to be kept in lockstep — `fetch_by_token/2`
  compares `now` against `last_used_at` directly and, if still valid, extends it to `now`
  in the same call. `:now` is an injectable option throughout so tests can move time
  without `Process.sleep/1`.
  """

  import Ecto.Query, only: [from: 2]

  alias WeddingPlanner.Accounts.Passkey
  alias WeddingPlanner.Accounts.User
  alias WeddingPlanner.Accounts.UserSession
  alias WeddingPlanner.Repo

  @ttl_days 30
  @ttl_seconds @ttl_days * 24 * 60 * 60
  @token_bytes 32

  @doc "AUTH-10: the sliding expiry window, in days."
  @spec ttl_days() :: pos_integer()
  def ttl_days, do: @ttl_days

  @doc """
  Establishes a new session for `user`, opened by `passkey` (or `nil` — see the
  migration's rationale for why that's allowed even though every real login has one).

  Returns the persisted session and the raw token (the session's own `:token` field,
  handed back separately so the caller doesn't have to know the schema stores it raw).

  Options:

    * `:now` — the moment the session starts, defaulting to the current UTC second.
  """
  @spec create_session(User.t(), Passkey.t() | nil, keyword()) ::
          {:ok, UserSession.t(), binary()} | {:error, Ecto.Changeset.t()}
  def create_session(user, passkey \\ nil, opts \\ [])

  def create_session(%User{id: user_id}, passkey, opts) when is_integer(user_id) do
    now = Keyword.get_lazy(opts, :now, &now/0)
    token = :crypto.strong_rand_bytes(@token_bytes)

    %UserSession{user_id: user_id, passkey_id: passkey_id(passkey)}
    |> UserSession.create_changeset(%{token: token, last_used_at: now})
    |> Repo.insert()
    |> case do
      {:ok, session} -> {:ok, session, token}
      {:error, changeset} -> {:error, changeset}
    end
  end

  @doc """
  Resolves `token` (raw bytes) to its session, preloaded with `:user`, extending the
  sliding window to `now` (`AUTH-10`). Returns `:error` for a token that doesn't exist or
  has expired — a caller cannot distinguish the two, deliberately, since either way there
  is no valid session to use.

  Options:

    * `:now` — the moment to check and extend to, defaulting to the current UTC second.
  """
  @spec fetch_by_token(binary(), keyword()) :: {:ok, UserSession.t()} | :error
  def fetch_by_token(token, opts \\ []) when is_binary(token) do
    now = Keyword.get_lazy(opts, :now, &now/0)

    case Repo.get_by(UserSession, token: token) do
      nil ->
        :error

      %UserSession{} = session ->
        if expired?(session, now) do
          :error
        else
          session = session |> UserSession.touch_changeset(now) |> Repo.update!()
          {:ok, Repo.preload(session, :user)}
        end
    end
  end

  @doc "AUTH-10: true once `now` is more than #{@ttl_days} days past `last_used_at`."
  @spec expired?(UserSession.t(), DateTime.t()) :: boolean()
  def expired?(%UserSession{last_used_at: last_used_at}, now) do
    DateTime.diff(now, last_used_at, :second) > @ttl_seconds
  end

  @doc "Ends a session (sign-out). Idempotent: deleting an unknown token is a no-op."
  @spec delete_session(binary()) :: :ok
  def delete_session(token) when is_binary(token) do
    Repo.delete_all(from s in UserSession, where: s.token == ^token)
    :ok
  end

  @doc """
  `DR-24`: deletes every session opened by `passkey` (used when that passkey is
  revoked), returning the raw tokens of the sessions just deleted. The caller — always
  the web layer, since this module (like the rest of `WeddingPlanner.Accounts`) never
  touches `Plug.Conn` or a socket — uses each token with
  `WeddingPlannerWeb.UserAuth.live_socket_id/1` to disconnect that session's live
  sockets, the same broadcast `WeddingPlannerWeb.SessionController.delete/2` already
  does for an ordinary sign-out.

  Must run **before** the passkey row itself is deleted: `user_sessions.passkey_id` is
  `on_delete: :nilify_all` (see that migration's rationale), so once the passkey is gone
  the foreign key trigger has already cleared `passkey_id` on any surviving session and
  there is nothing left here to find by it. `WeddingPlanner.Accounts.Passkeys.revoke/2`
  is the one caller, inside the same `mode: :immediate` transaction that then deletes
  the passkey.

  Purely additive: every other function in this module is unchanged.
  """
  @spec delete_sessions_for_passkey(Passkey.t()) :: [binary()]
  def delete_sessions_for_passkey(%Passkey{id: passkey_id}) do
    {_count, tokens} =
      Repo.delete_all(from(s in UserSession, where: s.passkey_id == ^passkey_id, select: s.token))

    tokens
  end

  defp passkey_id(%Passkey{id: id}), do: id
  defp passkey_id(nil), do: nil

  defp now, do: DateTime.utc_now() |> DateTime.truncate(:second)
end
