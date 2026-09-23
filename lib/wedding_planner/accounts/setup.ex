defmodule WeddingPlanner.Accounts.Setup do
  @moduledoc """
  `AUTH-03` / `D-33` bootstrap: whether the one-time setup flow is reachable, and the
  atomic creation of the very first user.

  This module holds no WebAuthn logic of its own — `lib/wedding_planner_web/live/
  setup_live.ex` is the caller, which creates the user here first and then drives
  `WeddingPlanner.Accounts.WebAuthn.begin_registration/1` /
  `finish_registration/4` against it (the WebAuthn user handle is `users.id`, so the row
  must exist before the ceremony starts — see that LiveView's moduledoc for the full
  create-first-delete-on-failure flow, `DR-22`).

  ## The setup token

  Read from `config :wedding_planner, :setup_token` (an operator-supplied environment
  variable, `config/runtime.exs` — never generated or logged by the app, `D-33`). A
  configured value shorter than `AUTH-03`'s 32-character minimum is treated exactly like
  an unset one: `configured_token/0` returns `nil` either way, so a short value can never
  be accepted, only ever logged (never its contents) as a misconfiguration.

  ## The race (`DR-22`)

  Two tabs could both observe "zero users exist" and then both try to create the first
  user. `create_first_user/1` closes that window by running the zero-users check and the
  insert inside a single `mode: :immediate` transaction: SQLite acquires its one
  write-lock at `BEGIN IMMEDIATE` rather than lazily at the first write statement, so a
  second concurrent transaction's own `BEGIN IMMEDIATE` blocks until the first commits
  (or times out per `:busy_timeout`) — by the time it runs its own check, the first
  user it was racing against already exists.
  """

  import Ecto.Query, only: [from: 1]

  require Logger

  alias WeddingPlanner.Accounts.User
  alias WeddingPlanner.Repo

  @min_token_length 32

  @doc "`AUTH-03`: true once any user exists, at which point setup is permanently done."
  @spec any_user?() :: boolean()
  def any_user?, do: Repo.exists?(from(u in User))

  @doc """
  The configured setup token, or `nil` if it is unset or shorter than the required 32
  characters (`AUTH-03`) — a short value is refused as though it were never configured
  at all, not merely rejected on comparison. Never logs the token itself; logs only the
  fact that a configured value was too short to ever be accepted.
  """
  @spec configured_token() :: String.t() | nil
  def configured_token do
    case Application.get_env(:wedding_planner, :setup_token) do
      token when is_binary(token) and byte_size(token) >= @min_token_length ->
        token

      token when is_binary(token) ->
        Logger.warning(
          "SETUP_TOKEN is configured but shorter than #{@min_token_length} characters " <>
            "(AUTH-03 requires at least that many); treating the setup flow as unavailable " <>
            "until a longer value is set. The token's contents are never logged."
        )

        nil

      _ ->
        nil
    end
  end

  @doc "True when a usable (long enough) setup token is configured."
  @spec token_configured?() :: boolean()
  def token_configured?, do: not is_nil(configured_token())

  @doc """
  Constant-time comparison of `candidate` against the configured token (`AUTH-03`). Always
  `false` when no usable token is configured, including a too-short one.
  """
  @spec valid_token?(String.t()) :: boolean()
  def valid_token?(candidate) when is_binary(candidate) do
    case configured_token() do
      nil -> false
      token -> Plug.Crypto.secure_compare(token, candidate)
    end
  end

  @doc """
  Atomically creates the first user, or refuses if one already exists by the time this
  transaction's write-lock is granted (`DR-22`'s race guard — see the moduledoc).

  `attrs` is passed straight to `WeddingPlanner.Accounts.User.changeset/2`.
  """
  @spec create_first_user(map()) ::
          {:ok, User.t()} | {:error, :already_exists | Ecto.Changeset.t()}
  def create_first_user(attrs) do
    Repo.transaction(
      fn ->
        if any_user?() do
          Repo.rollback(:already_exists)
        else
          case %User{} |> User.changeset(attrs) |> Repo.insert() do
            {:ok, user} -> user
            {:error, changeset} -> Repo.rollback(changeset)
          end
        end
      end,
      mode: :immediate
    )
  end
end
