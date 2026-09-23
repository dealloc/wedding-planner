defmodule WeddingPlanner.Accounts.SetupGuard do
  @moduledoc """
  `DR-22`: deletes the provisional user created for a bootstrap setup ceremony
  (`WeddingPlanner.Accounts.Setup.create_first_user/1`) if that ceremony never completes
  because its owning LiveView process goes away — tab closed, navigated away, crashed —
  before either a passkey is registered or the LiveView itself deletes the user (a
  cancelled/failed ceremony while the LiveView is still alive).

  A LiveView's `terminate/2` is not reliably invoked on every disconnect, so this is a
  small, separate process instead, watching the owner via `Process.monitor/1` rather
  than a link. This is a deliberate choice, not a stylistic one: a `GenServer` started
  with `start_link/2` has a special relationship with the process that started it (its
  OTP "parent") — even a `Process.flag(:trap_exit, true)` guard does not protect it from
  *that specific* link. `:gen_server` intercepts an `{:EXIT, parent, reason}` from its own
  parent before the callback module ever sees it, and terminates immediately with that
  reason, bypassing any user-defined `handle_info/2` clause entirely. A plain monitor has
  no such special case — the owner's death always arrives as an ordinary `:DOWN` message
  routed straight to `handle_info/2` — which is why this module uses `GenServer.start/2`
  (unlinked) plus an explicit monitor, not `start_link/2` plus `trap_exit`.

  Every ceremony outcome ends the guard one of two ways:

    * the owner calls `disarm/1` — the ceremony completed, or the owner already deleted
      the user itself (cancel/error) and just needs the guard to stand down; either way
      the guard stops without touching the database, or
    * the owner dies first — the guard's `:DOWN` handler deletes the user, then stops
      itself.

  There is no third outcome: once started, a guard always terminates via exactly one of
  these two paths. Deleting an already-deleted user (a stale delete, raising
  `Ecto.StaleEntryError`) or hitting an unexpected error is logged and swallowed rather
  than raised — a crash inside `handle_info/2` here must never turn into a `:DOWN` for
  whoever might be monitoring the guard itself expecting a clean stop.

  A guard that never sees either event (the whole node goes down mid-ceremony) leaves an
  orphaned provisional user; this is the accepted residual risk noted in the setup task —
  its recovery is a later, separate operator command, not something this module tries to
  engineer around.
  """
  use GenServer

  require Logger

  alias WeddingPlanner.Accounts.User
  alias WeddingPlanner.Repo

  @doc """
  Starts a guard that will delete `user_id` if `owner` exits before `disarm/1` is
  called. Deliberately unlinked (see the moduledoc) — `owner` is watched via
  `Process.monitor/1`, not via the caller/parent link `start_link` would create.
  """
  @spec start(owner: pid(), user_id: pos_integer()) :: GenServer.on_start()
  def start(opts) do
    owner = Keyword.fetch!(opts, :owner)
    user_id = Keyword.fetch!(opts, :user_id)
    GenServer.start(__MODULE__, %{owner: owner, user_id: user_id})
  end

  @doc """
  Tells `pid` its job is done: no delete should happen, regardless of what becomes of the
  owner afterwards. Safe to call even if the guard has already stopped on its own.
  """
  @spec disarm(pid()) :: :ok
  def disarm(pid) do
    GenServer.stop(pid, :normal)
    :ok
  catch
    :exit, _ -> :ok
  end

  @impl true
  def init(%{owner: owner} = state) do
    Process.monitor(owner)
    {:ok, state}
  end

  @impl true
  def handle_info(
        {:DOWN, _ref, :process, owner, _reason},
        %{owner: owner, user_id: user_id} = state
      ) do
    delete_provisional_user(user_id)
    {:stop, :normal, state}
  end

  def handle_info(_message, state), do: {:noreply, state}

  defp delete_provisional_user(user_id) do
    Repo.delete(%User{id: user_id})
    :ok
  rescue
    error ->
      Logger.warning(
        "SetupGuard: could not delete provisional user #{user_id} after its bootstrap " <>
          "ceremony was abandoned: #{Exception.format(:error, error, [])}"
      )

      :ok
  end
end
