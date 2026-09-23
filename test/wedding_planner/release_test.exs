defmodule WeddingPlanner.ReleaseTest do
  @moduledoc """
  `AUTH-09`: the operator recovery release command. Exercises
  `WeddingPlanner.Release.generate_recovery_link/1` — the testable core of `recover/1`
  (see that module's moduledoc for why `recover/1` itself, which calls `System.halt/1`
  on failure, is not something `mix test` can safely invoke directly).

  The end-to-end proof that a generated link actually registers a passkey lives in the
  last `describe` block, driving the real `/enroll/:token` ceremony with
  `WeddingPlanner.SoftwareAuthenticator`, the same way `EnrollmentLiveTest` does for the
  other flavours.

  `async: false`: the last test mutates shared rows across LiveView processes, same
  reasoning as `EnrollmentLiveTest`.
  """
  use WeddingPlannerWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias WeddingPlanner.Accounts.EnrollmentLink
  alias WeddingPlanner.Accounts.Passkey
  alias WeddingPlanner.Accounts.User
  alias WeddingPlanner.Log.Entry
  alias WeddingPlanner.Release
  alias WeddingPlanner.Repo
  alias WeddingPlanner.SoftwareAuthenticator

  describe "generate_recovery_link/1" do
    test "generates a link for an existing user, looked up by id" do
      user = insert_user!("Wannes")

      assert {:ok, url} = Release.generate_recovery_link(to_string(user.id))
      assert url =~ "/enroll/"

      assert [link] = Repo.all(EnrollmentLink)
      assert link.flavour == "recovery"
      assert is_nil(link.issuing_user_id)
      assert link.target_user_id == user.id
      assert url =~ link.token
    end

    test "generates a link for an existing user, looked up by display name" do
      user = insert_user!("Ambre")

      assert {:ok, url} = Release.generate_recovery_link("Ambre")

      assert [link] = Repo.all(EnrollmentLink)
      assert link.target_user_id == user.id
      assert url =~ link.token
    end

    test "fails clearly for an unknown numeric id" do
      insert_user!("Wannes")

      assert {:error, :not_found} = Release.generate_recovery_link("999999")
      assert Repo.all(EnrollmentLink) == []
    end

    test "fails clearly for an unknown display name" do
      insert_user!("Wannes")

      assert {:error, :not_found} = Release.generate_recovery_link("Nobody")
      assert Repo.all(EnrollmentLink) == []
    end

    test "the generated link is single-use and expires later than the 15-minute default" do
      user = insert_user!("Wannes")
      before = DateTime.utc_now()

      {:ok, _url} = Release.generate_recovery_link(to_string(user.id))

      [link] = Repo.all(EnrollmentLink)
      assert is_nil(link.used_at)
      assert is_nil(link.revoked_at)
      # AUTH-06's default is 15 minutes; the recovery command widens it (see
      # EnrollmentLinks.create_recovery_link/1) — assert it is meaningfully longer
      # rather than pinning the exact value here.
      assert DateTime.diff(link.expires_at, before, :second) > 15 * 60
    end

    test "AUTH-11: logs creation, attributed to the target user, described as an operator action" do
      user = insert_user!("Wannes")

      {:ok, _url} = Release.generate_recovery_link(to_string(user.id))

      [link] = Repo.all(EnrollmentLink)
      entry = Repo.get_by(Entry, entity_type: "enrollment_link", entity_id: link.id)

      assert entry.user_id == user.id
      assert entry.description =~ "operator"
      assert entry.description =~ "Wannes"
    end

    test "the printed URL never appears in a Logger-emitted message" do
      user = insert_user!("Wannes")

      log =
        ExUnit.CaptureLog.capture_log(fn ->
          {:ok, _url} = Release.generate_recovery_link(to_string(user.id))
        end)

      [link] = Repo.all(EnrollmentLink)
      refute log =~ link.token
    end
  end

  describe "AUTH-09: a command-generated link registers a passkey end to end" do
    test "the printed URL's token opens the recovery landing page and registers a passkey", %{
      conn: conn
    } do
      user = insert_user!("Wannes")

      {:ok, url} = Release.generate_recovery_link(to_string(user.id))
      token = url |> String.split("/enroll/") |> List.last()

      {:ok, view, html} = live(conn, ~p"/enroll/#{token}")
      assert html =~ "recovery"
      assert has_element?(view, "#enrollment-register-button")

      view |> element("#enrollment-register-button") |> render_click()
      assert_push_event(view, "passkey:create", options)

      {_authenticator, credential} = SoftwareAuthenticator.create(options)
      render_hook(view, "passkey:registration-success", credential)

      assert has_element?(view, "#enrollment-completed")
      assert [passkey] = Repo.all(Passkey)
      assert passkey.user_id == user.id

      [link] = Repo.all(EnrollmentLink)
      assert %EnrollmentLink{used_at: %DateTime{}} = link
    end
  end

  defp insert_user!(display_name) do
    %User{} |> User.changeset(%{display_name: display_name}) |> Repo.insert!()
  end
end
