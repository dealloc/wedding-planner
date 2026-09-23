defmodule WeddingPlanner.Accounts.ScopeTest do
  @moduledoc """
  Minimal `WeddingPlanner.Accounts.Scope` builder — no session/plug wiring, that belongs
  to a later auth slice.
  """
  use WeddingPlanner.DataCase, async: true

  alias WeddingPlanner.Accounts.Scope
  alias WeddingPlanner.Accounts.User

  test "for_user/1 carries the given user" do
    {:ok, user} = %User{} |> User.changeset(%{display_name: "Wannes"}) |> Repo.insert()

    assert %Scope{user: ^user} = Scope.for_user(user)
  end

  test "for_user/1 builds an anonymous scope for nil" do
    assert %Scope{user: nil} = Scope.for_user(nil)
  end
end
