defmodule WeddingPlannerWeb.ConnCase do
  @moduledoc """
  This module defines the test case to be used by
  tests that require setting up a connection.

  Such tests rely on `Phoenix.ConnTest` and also
  import other functionality to make it easier
  to build common data structures and query the data layer.

  Finally, if the test case interacts with the database,
  we enable the SQL sandbox, so changes done to the database
  are reverted at the end of every test. If you are using
  PostgreSQL, you can even run database tests asynchronously
  by setting `use WeddingPlannerWeb.ConnCase, async: true`, although
  this option is not recommended for other databases.
  """

  use ExUnit.CaseTemplate

  using do
    quote do
      # The default endpoint for testing
      @endpoint WeddingPlannerWeb.Endpoint

      use WeddingPlannerWeb, :verified_routes

      # Import conveniences for testing with connections
      import Plug.Conn
      import Phoenix.ConnTest
      import WeddingPlannerWeb.ConnCase
    end
  end

  setup tags do
    WeddingPlanner.DataCase.setup_sandbox(tags)
    {:ok, conn: Phoenix.ConnTest.build_conn()}
  end

  @doc """
  Signs `conn` in as `user` for a test, the same way `WeddingPlannerWeb.SessionController`
  does after a real ceremony — establishes a real `WeddingPlanner.Accounts.UserSession`
  row (so `AUTH-10`'s sliding expiry and `WeddingPlannerWeb.UserAuth`'s lookup are
  exercised for real, not bypassed) and puts its token in the test session.

  `opts` is passed straight through to `WeddingPlanner.Accounts.Sessions.create_session/3`
  (e.g. `now:` to seed a session at a particular moment for expiry tests).
  """
  def log_in_user(conn, user, passkey \\ nil, opts \\ []) do
    {:ok, _session, token} = WeddingPlanner.Accounts.Sessions.create_session(user, passkey, opts)

    conn
    |> Phoenix.ConnTest.init_test_session(%{})
    |> Plug.Conn.put_session("user_session_token", token)
    |> Plug.Conn.put_session("live_socket_id", WeddingPlannerWeb.UserAuth.live_socket_id(token))
  end
end
