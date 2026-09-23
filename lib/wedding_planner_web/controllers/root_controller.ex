defmodule WeddingPlannerWeb.RootController do
  @moduledoc """
  `AUTH-01` leaves no public home page — `/` simply forwards to `/home`. Replaces the
  `phx.new` scaffold `PageController`, which served a marketing welcome page with no
  place in a two-person private app.

  `/home` sits behind the authenticated `live_session` (`WeddingPlannerWeb.UserAuth`), so
  an unauthenticated visitor lands here and is redirected straight on to `/login`
  (`return_to=/home`), then back to `/home` once signed in.
  """
  use WeddingPlannerWeb, :controller

  def redirect_home(conn, _params) do
    redirect(conn, to: ~p"/home")
  end
end
