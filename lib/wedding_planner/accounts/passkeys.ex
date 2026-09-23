defmodule WeddingPlanner.Accounts.Passkeys do
  @moduledoc """
  Passkey management (`AUTH-08`): listing, renaming and revoking a user's own
  registered passkeys. Mirrors `WeddingPlanner.Events`' context/log pattern (the task 22
  exemplar) — mutations here log through `WeddingPlanner.Log` themselves rather than
  leaving it to the caller.

  ## Scoping to "your own passkeys only" (`AUTH-08`)

  `get_own/2` is the one lookup this module exposes for a single passkey by id, and it
  is scoped to the given user: a passkey that exists but belongs to someone else comes
  back `nil`, indistinguishable from a nonexistent id. Every mutation below takes the
  already-scoped `Passkey.t()` this (or `list_for_user/1`) returns, never a bare id —
  `WeddingPlannerWeb.Live.DevicesLive` always resolves a client-supplied id through
  `get_own/2` first, including for a crafted event that names another user's passkey.

  ## The last-passkey guard is atomic, and covers session cleanup too (`AUTH-08`, `DR-24`)

  `revoke/2` refuses to delete a user's last remaining passkey. The check ("this isn't
  their last one"), the deletion of every session that passkey opened (`DR-24`), and the
  passkey delete itself all happen inside one `mode: :immediate` SQLite transaction —
  the same pattern `WeddingPlanner.Accounts.Setup.create_first_user/1` uses for its own
  read-then-write race (see that module's moduledoc): `BEGIN IMMEDIATE` takes SQLite's
  one write-lock before the transaction reads anything, so a second, concurrent
  `revoke/2` racing to delete the *other* of a user's last two passkeys blocks until the
  first one commits — by the time its own count check runs, only one passkey is left,
  and it correctly refuses. Two tabs racing to revoke each other's last two passkeys can
  therefore never both succeed, and zero passkeys is never reachable through this
  function.

  Sessions are deleted **before** the passkey row, deliberately: `user_sessions.passkey_id`
  is `on_delete: :nilify_all` (see that migration), so deleting the passkey first would
  have already cleared `passkey_id` on any surviving session by the time this code tried
  to find them by it.
  """

  import Ecto.Query, only: [from: 2]

  alias WeddingPlanner.Accounts.Passkey
  alias WeddingPlanner.Accounts.Scope
  alias WeddingPlanner.Accounts.Sessions
  alias WeddingPlanner.Accounts.User
  alias WeddingPlanner.Log
  alias WeddingPlanner.Repo

  @doc "AUTH-08: `user`'s own passkeys, oldest-registered first."
  @spec list_for_user(User.t()) :: [Passkey.t()]
  def list_for_user(%User{id: user_id}) do
    Repo.all(
      from p in Passkey,
        where: p.user_id == ^user_id,
        order_by: [asc: p.registered_at, asc: p.id]
    )
  end

  @doc "How many passkeys `user` has registered — used to disable the last one's revoke control."
  @spec count_for_user(User.t()) :: non_neg_integer()
  def count_for_user(%User{id: user_id}) do
    Repo.aggregate(from(p in Passkey, where: p.user_id == ^user_id), :count, :id)
  end

  @doc """
  Fetches passkey `id` scoped to `user` — `nil` both when it does not exist and when it
  belongs to someone else (`AUTH-08`: "their own passkeys only" — a passkey id that
  isn't theirs must be indistinguishable from a nonexistent one to every caller,
  including a crafted client event carrying someone else's id).
  """
  @spec get_own(User.t(), term()) :: Passkey.t() | nil
  def get_own(%User{id: user_id}, id) do
    Repo.get_by(Passkey, id: id, user_id: user_id)
  end

  @doc """
  `AUTH-08`/`AUTH-11`: renames `passkey`, logging "…renamed passkey 'Old' → 'New'"
  (`XC-10` style) only when the name actually changed — resubmitting the same name (a
  no-op save) writes nothing to the log.
  """
  @spec rename(Scope.t(), Passkey.t(), map()) ::
          {:ok, Passkey.t()} | {:error, Ecto.Changeset.t()}
  def rename(%Scope{} = scope, %Passkey{} = passkey, attrs) do
    old_name = passkey.name

    with {:ok, renamed} <- passkey |> Passkey.rename_changeset(attrs) |> Repo.update() do
      if renamed.name != old_name do
        {:ok, _} =
          Log.entry(
            scope,
            {:passkey, renamed.id},
            "#{actor(scope)} renamed passkey '#{old_name}' → '#{renamed.name}'"
          )
      end

      {:ok, renamed}
    end
  end

  @doc """
  `AUTH-08`/`AUTH-11`/`DR-24`: revokes `passkey`.

  Refuses with `{:error, :last_passkey}` if it is the user's only remaining passkey —
  nothing is deleted, nothing is logged. On success, every session opened by `passkey`
  is deleted too (see the moduledoc for why sessions go first), the revocation is
  logged, and the deleted sessions' raw tokens are returned so the caller — necessarily
  the web layer, which owns `Plug.Conn`/the `Phoenix.Endpoint` this context never
  touches — can disconnect their live sockets the same way
  `WeddingPlannerWeb.SessionController.delete/2` already does for an ordinary sign-out.

  The log entry is written only after the transaction has committed, so a refused
  (last-passkey) attempt never produces one, and a hypothetical mid-transaction failure
  can't leave a log entry for a revocation that was rolled back.
  """
  @spec revoke(Scope.t(), Passkey.t()) ::
          {:ok, %{passkey: Passkey.t(), session_tokens: [binary()]}} | {:error, :last_passkey}
  def revoke(%Scope{} = scope, %Passkey{id: id, user_id: user_id} = passkey) do
    transaction_result =
      Repo.transaction(
        fn ->
          count = Repo.aggregate(from(p in Passkey, where: p.user_id == ^user_id), :count, :id)

          if count <= 1 do
            Repo.rollback(:last_passkey)
          else
            tokens = Sessions.delete_sessions_for_passkey(passkey)
            {:ok, _deleted} = Repo.delete(passkey)
            tokens
          end
        end,
        mode: :immediate
      )

    case transaction_result do
      {:ok, tokens} ->
        {:ok, _} =
          Log.entry(scope, {:passkey, id}, "#{actor(scope)} revoked passkey '#{passkey.name}'")

        {:ok, %{passkey: passkey, session_tokens: tokens}}

      {:error, :last_passkey} ->
        {:error, :last_passkey}
    end
  end

  defp actor(%Scope{user: %User{display_name: name}}), do: name
end
