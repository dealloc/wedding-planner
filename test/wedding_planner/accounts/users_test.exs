defmodule WeddingPlanner.Accounts.UsersTest do
  @moduledoc """
  `DR-22`: a user with no registered passkey is *provisional* and must never be
  assignable as a task owner.
  """
  use WeddingPlanner.DataCase, async: true

  alias WeddingPlanner.Accounts.Passkey
  alias WeddingPlanner.Accounts.User
  alias WeddingPlanner.Accounts.Users

  describe "list_assignable/0" do
    test "excludes a provisional user with no passkey" do
      _provisional = insert_user!("Provisional")
      assignable = insert_user!("Wannes")
      insert_passkey!(assignable)

      assert Enum.map(Users.list_assignable(), & &1.id) == [assignable.id]
    end

    test "includes every user with at least one passkey, ordered by display name" do
      bea = insert_user!("Bea")
      insert_passkey!(bea)
      annick = insert_user!("Annick")
      insert_passkey!(annick)

      assert Enum.map(Users.list_assignable(), & &1.display_name) == ["Annick", "Bea"]
    end

    test "a user with more than one passkey is listed once" do
      user = insert_user!("Wannes")
      insert_passkey!(user, "Phone")
      insert_passkey!(user, "Laptop")

      assert Enum.map(Users.list_assignable(), & &1.id) == [user.id]
    end

    test "empty when no user has a passkey" do
      insert_user!("Provisional")
      assert Users.list_assignable() == []
    end
  end

  describe "assignable?/1" do
    test "true for a user with a passkey" do
      user = insert_user!("Wannes")
      insert_passkey!(user)
      assert Users.assignable?(user.id)
    end

    test "false for a provisional user with no passkey" do
      user = insert_user!("Provisional")
      refute Users.assignable?(user.id)
    end

    test "false for a non-existent user id" do
      refute Users.assignable?(-1)
    end

    test "false for nil" do
      refute Users.assignable?(nil)
    end
  end

  defp insert_user!(display_name) do
    %User{} |> User.changeset(%{display_name: display_name}) |> Repo.insert!()
  end

  defp insert_passkey!(user, name \\ "Passkey") do
    %Passkey{user_id: user.id}
    |> Passkey.registration_changeset(%{
      credential_id: :crypto.strong_rand_bytes(16),
      public_key: :crypto.strong_rand_bytes(16),
      name: name,
      registered_at: DateTime.utc_now() |> DateTime.truncate(:second)
    })
    |> Repo.insert!()
  end
end
