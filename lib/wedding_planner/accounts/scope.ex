defmodule WeddingPlanner.Accounts.Scope do
  @moduledoc """
  The current user, carried through a request or a call so business logic never has to
  ask "who is doing this?" via a global.

  This is a deliberately minimal stand-in. The full session/plug/`on_mount` wiring that
  would populate `@current_scope` on every LiveView (Phoenix 1.8 convention,
  `AGENTS.md`) belongs to the authentication slice (tasks 12-18), which has not landed
  yet. It is created here only so `WeddingPlanner.Log.entry/3` and
  `WeddingPlanner.Log.action/3` have a real, stable argument type to be built against —
  `AUTH-11` requires enrollment link creation, passkey registration and revocation to be
  logged through this same service once that slice exists.

  Do not add session/plug/`on_mount` integration here; that is out of scope for this
  task.
  """

  alias WeddingPlanner.Accounts.User

  @type t :: %__MODULE__{user: User.t() | nil}

  defstruct user: nil

  @doc "Builds a scope for `user`, or an anonymous scope for `nil`."
  @spec for_user(User.t() | nil) :: t()
  def for_user(%User{} = user), do: %__MODULE__{user: user}
  def for_user(nil), do: %__MODULE__{user: nil}
end
