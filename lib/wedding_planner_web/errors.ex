defmodule WeddingPlannerWeb.NotFoundError do
  @moduledoc """
  Raised to render a plain 404 from code that isn't a `Plug`/controller action — most
  notably a LiveView's `mount/3` (`AUTH-03`: once any user exists, `/setup` must behave
  as though it doesn't exist, re-checked on every mount rather than a flag).

  `plug_status: 404` is the field `Plug.Exception`'s default (`Any`) implementation
  looks for on any struct it doesn't have a specific implementation for — the same
  mechanism `Ecto.NoResultsError` relies on to turn a plain `Repo.get!/2` miss into a 404
  page instead of a 500.
  """
  defexception message: "not found", plug_status: 404
end
