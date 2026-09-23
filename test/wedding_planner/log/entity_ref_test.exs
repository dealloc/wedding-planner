defmodule WeddingPlanner.Log.EntityRefTest do
  @moduledoc """
  `XC-10`'s resolution mechanism: a navigable link when the entity exists and has a
  page, plain text when it does not (deleted, or no page built for its type yet), and
  the extensibility a later slice needs without touching this test's module.
  """
  use WeddingPlanner.DataCase, async: false

  alias WeddingPlanner.Accounts.EnrollmentLink
  alias WeddingPlanner.Accounts.Passkey
  alias WeddingPlanner.Accounts.User
  alias WeddingPlanner.Log.EntityRef

  setup do
    {:ok, user} = %User{} |> User.changeset(%{display_name: "Wannes"}) |> Repo.insert()
    %{user: user}
  end

  describe "enrollment link resolution" do
    test "a device link resolves to a readable 'Device link' label, not the raw flavour", %{
      user: user
    } do
      {:ok, link} = user |> EnrollmentLink.device_link_changeset() |> Repo.insert()

      assert {:text, "Device link"} = EntityRef.resolve("enrollment_link", link.id)
    end

    test "a user-invitation link resolves to a readable 'Invitation link' label", %{user: user} do
      {:ok, link} = user |> EnrollmentLink.user_invitation_link_changeset() |> Repo.insert()

      assert {:text, "Invitation link"} = EntityRef.resolve("enrollment_link", link.id)
    end

    test "a recovery link resolves to a readable 'Recovery link' label", %{user: user} do
      {:ok, link} = user |> EnrollmentLink.recovery_link_changeset() |> Repo.insert()

      assert {:text, "Recovery link"} = EntityRef.resolve("enrollment_link", link.id)
    end

    test "a deleted enrollment link still degrades to plain text instead of raising", %{
      user: user
    } do
      {:ok, link} = user |> EnrollmentLink.device_link_changeset() |> Repo.insert()
      Repo.delete!(link)

      assert {:text, label} = EntityRef.resolve("enrollment_link", link.id)
      assert label =~ "##{link.id}"
    end
  end

  test "an existing user degrades to plain text (no user page exists yet)", %{user: user} do
    assert {:text, "Wannes"} = EntityRef.resolve("user", user.id)
  end

  test "an existing passkey degrades to plain text (no passkey page exists yet)", %{user: user} do
    {:ok, passkey} =
      %Passkey{user_id: user.id}
      |> Passkey.registration_changeset(%{
        credential_id: <<1, 2, 3>>,
        public_key: <<4, 5, 6>>,
        name: "Wannes' phone",
        registered_at: DateTime.utc_now() |> DateTime.truncate(:second)
      })
      |> Repo.insert()

    assert {:text, "Wannes' phone"} = EntityRef.resolve("passkey", passkey.id)
  end

  test "a deleted entity degrades to plain text instead of raising", %{user: user} do
    {:ok, passkey} =
      %Passkey{user_id: user.id}
      |> Passkey.registration_changeset(%{
        credential_id: <<7, 8, 9>>,
        public_key: <<10, 11, 12>>,
        name: "Old phone",
        registered_at: DateTime.utc_now() |> DateTime.truncate(:second)
      })
      |> Repo.insert()

    Repo.delete!(passkey)

    assert {:text, label} = EntityRef.resolve("passkey", passkey.id)
    assert label =~ "##{passkey.id}"
  end

  test "an unregistered entity type degrades to plain text instead of raising" do
    assert {:text, label} = EntityRef.resolve("spaceship", 1)
    assert label =~ "Spaceship"
    assert label =~ "#1"
  end

  test "a later slice can register a resolver, via app config, that yields a navigable link" do
    Application.put_env(:wedding_planner, :log_entity_resolvers, %{
      "widget" => fn _id -> {:ok, "Test widget", "/widgets/1"} end
    })

    on_exit(fn -> Application.delete_env(:wedding_planner, :log_entity_resolvers) end)

    assert {:link, "Test widget", "/widgets/1"} = EntityRef.resolve("widget", 1)
  end

  test "an app-registered resolver can still report a deleted entity as plain text" do
    Application.put_env(:wedding_planner, :log_entity_resolvers, %{
      "widget" => fn _id -> :error end
    })

    on_exit(fn -> Application.delete_env(:wedding_planner, :log_entity_resolvers) end)

    assert {:text, _label} = EntityRef.resolve("widget", 1)
  end
end
