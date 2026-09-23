defmodule WeddingPlanner.Accounts.SetupTest do
  @moduledoc """
  `AUTH-03` / `D-33`: token validation and the (non-concurrent path of the) atomic
  first-user creation. `DR-22`'s race guard is proven separately against real concurrent
  connections in `WeddingPlanner.Accounts.SetupConcurrencyTest` — the SQL sandbox used
  here serializes every query through one connection, which would make "only one
  winner" trivially true regardless of whether `create_first_user/1` is actually atomic.

  `async: false`: every test here mutates the shared `:wedding_planner, :setup_token`
  application environment key, which is process-global state.
  """
  use WeddingPlanner.DataCase, async: false

  import ExUnit.CaptureLog

  alias WeddingPlanner.Accounts.Setup
  alias WeddingPlanner.Accounts.User

  @valid_token String.duplicate("a", 32)

  setup do
    previous = Application.get_env(:wedding_planner, :setup_token)
    Application.delete_env(:wedding_planner, :setup_token)

    on_exit(fn ->
      case previous do
        nil -> Application.delete_env(:wedding_planner, :setup_token)
        value -> Application.put_env(:wedding_planner, :setup_token, value)
      end
    end)

    :ok
  end

  describe "any_user?/0" do
    test "false with no users" do
      refute Setup.any_user?()
    end

    test "true once a user exists" do
      insert_user!("Wannes")
      assert Setup.any_user?()
    end
  end

  describe "configured_token/0 and token_configured?/0" do
    test "nil and false when unset" do
      assert Setup.configured_token() == nil
      refute Setup.token_configured?()
    end

    test "the token itself once it is at least 32 characters" do
      Application.put_env(:wedding_planner, :setup_token, @valid_token)

      assert Setup.configured_token() == @valid_token
      assert Setup.token_configured?()
    end

    test "nil, false, and a warning naming the reason (never the token) when too short" do
      Application.put_env(:wedding_planner, :setup_token, "too-short-secret")

      log =
        capture_log(fn ->
          refute Setup.token_configured?()
          assert Setup.configured_token() == nil
        end)

      assert log =~ "shorter than 32 characters"
      refute log =~ "too-short-secret"
    end
  end

  describe "valid_token?/1" do
    test "true only for the exact configured token, compared in constant time" do
      Application.put_env(:wedding_planner, :setup_token, @valid_token)

      assert Setup.valid_token?(@valid_token)
      refute Setup.valid_token?(String.duplicate("b", 32))
      refute Setup.valid_token?(String.slice(@valid_token, 0, 31))
    end

    test "false when no token is configured" do
      refute Setup.valid_token?(@valid_token)
    end

    test "false when the configured token is too short, even given verbatim" do
      Application.put_env(:wedding_planner, :setup_token, "short")
      refute Setup.valid_token?("short")
    end
  end

  describe "create_first_user/1" do
    test "creates the user when none exists yet" do
      assert {:ok, %User{} = user} = Setup.create_first_user(%{"display_name" => "Wannes"})
      assert user.display_name == "Wannes"
      assert Repo.aggregate(User, :count) == 1
    end

    test "refuses once a user already exists, and creates no second one" do
      insert_user!("Wannes")

      assert {:error, :already_exists} =
               Setup.create_first_user(%{"display_name" => "Partner"})

      assert Repo.aggregate(User, :count) == 1
      assert [%User{display_name: "Wannes"}] = Repo.all(User)
    end
  end

  defp insert_user!(display_name) do
    %User{} |> User.changeset(%{display_name: display_name}) |> Repo.insert!()
  end
end
