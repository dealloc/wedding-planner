defmodule WeddingPlanner.Accounts.Users do
  @moduledoc """
  Owner-candidate queries for task assignment (`DR-22`).

  A user row can exist before it has any passkey — created at the start of a bootstrap
  or enrollment ceremony (`WeddingPlanner.Accounts.User`'s moduledoc, AUTH-03/AUTH-05)
  and deleted again if that ceremony fails. Such a **provisional** user must never be
  referenced from anywhere else in the app, including as a task owner. This module is
  the query boundary that draws that line for task ownership: a user only becomes
  "assignable" once it has registered at least one passkey.

  Deliberately its own module rather than functions added to
  `WeddingPlanner.Accounts.Passkey`/`Sessions`/`UserSession` — those are being changed
  by another task in parallel.
  """

  import Ecto.Query

  alias WeddingPlanner.Accounts.Passkey
  alias WeddingPlanner.Accounts.User
  alias WeddingPlanner.Repo

  @doc "Users with at least one registered passkey, ordered by display name (`DR-22`)."
  @spec list_assignable() :: [User.t()]
  def list_assignable do
    # A join + `distinct(u.id)` here would need SQLite to support the Postgres-style
    # `DISTINCT ON (col)` idiom Ecto's `distinct: field` compiles to, which it doesn't
    # (`ecto_sqlite3` raises "DISTINCT with multiple columns is not supported" even for
    # a single field). `distinct: true` compiles to a plain `SELECT DISTINCT`, which
    # dedupes on the one selected column — exactly what's needed here — so a subquery
    # of distinct owning user ids sidesteps the unsupported form entirely.
    owner_ids = from p in Passkey, distinct: true, select: p.user_id

    User
    |> where([u], u.id in subquery(owner_ids))
    |> order_by([u], asc: u.display_name)
    |> Repo.all()
  end

  @doc """
  `AUTH-12`: changes the acting user's **own** display name (no user can rename another:
  the target is always `scope.user`). Logged against the settings, since a user has no
  detail page: "Wannes Gennar changed their name to 'Wannes'". A blank or over-long name
  is a changeset error and writes nothing; an unchanged name is a no-op.
  """
  @spec rename_self(WeddingPlanner.Accounts.Scope.t(), String.t()) ::
          {:ok, User.t()} | {:error, Ecto.Changeset.t()}
  def rename_self(%WeddingPlanner.Accounts.Scope{user: %User{} = user} = scope, display_name) do
    changeset = User.changeset(Repo.get!(User, user.id), %{display_name: display_name})

    if changeset.changes == %{} and changeset.valid? do
      {:ok, user}
    else
      with {:ok, updated} <- Repo.update(changeset) do
        {:ok, _} =
          WeddingPlanner.Log.entry(
            scope,
            {:settings, WeddingPlanner.Settings.get().id},
            "#{user.display_name} changed their name to '#{updated.display_name}'"
          )

        {:ok, updated}
      end
    end
  end

  @doc """
  Whether `user_id` may be assigned as a task owner: it must reference a user with at
  least one registered passkey (`DR-22`). `nil` is never assignable.
  """
  @spec assignable?(term() | nil) :: boolean()
  def assignable?(nil), do: false

  def assignable?(user_id) do
    Repo.exists?(from p in Passkey, where: p.user_id == ^user_id)
  end
end
