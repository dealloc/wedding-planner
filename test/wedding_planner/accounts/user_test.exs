defmodule WeddingPlanner.Accounts.UserTest do
  use WeddingPlanner.DataCase, async: true

  alias WeddingPlanner.Accounts.User

  test "a user is created with a display name" do
    {:ok, user} =
      %User{}
      |> User.changeset(%{display_name: "Wannes"})
      |> Repo.insert()

    assert user.display_name == "Wannes"
  end

  test "a display name is required" do
    changeset = User.changeset(%User{}, %{})
    refute changeset.valid?
    assert "can't be blank" in errors_on(changeset).display_name
  end
end
