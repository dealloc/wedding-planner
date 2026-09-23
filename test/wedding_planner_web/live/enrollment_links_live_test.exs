defmodule WeddingPlannerWeb.Live.EnrollmentLinksLiveTest do
  @moduledoc """
  `AUTH-04` through `AUTH-07`, `AUTH-11` — the enrollment link generation screen. Signed
  in as one user throughout; AUTH-07 (any user can revoke any link) is exercised at the
  context level (`EnrollmentLinksTest`) and here only needs one signed-in user, since the
  screen has no concept of "my links" vs. "their links" — it lists every active link.
  """
  use WeddingPlannerWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias WeddingPlanner.Accounts.EnrollmentLink
  alias WeddingPlanner.Accounts.User
  alias WeddingPlanner.Log.Entry
  alias WeddingPlanner.Repo

  setup %{conn: conn} do
    user = insert_user!("Wannes")
    conn = log_in_user(conn, user)
    %{conn: conn, user: user}
  end

  test "renders the two creation buttons and an empty list", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/enrollment-links")

    assert has_element?(view, "#create-device-link-button")
    assert has_element?(view, "#create-invitation-link-button")
    assert has_element?(view, "#enrollment-links-empty")
  end

  describe "creating a device link" do
    test "AUTH-04, AUTH-06: shows the URL and QR together with the expiry, and logs it (AUTH-11)",
         %{conn: conn, user: user} do
      {:ok, view, _html} = live(conn, ~p"/enrollment-links")

      html = view |> element("#create-device-link-button") |> render_click()

      assert [link] = Repo.all(EnrollmentLink)
      assert link.flavour == "device"
      assert link.issuing_user_id == user.id

      document = LazyHTML.from_fragment(html)
      card_id = "links-#{link.id}"
      assert has_element?(view, "##{card_id}")

      [url_value] =
        document
        |> LazyHTML.query("##{card_id}-url")
        |> LazyHTML.attribute("value")

      assert url_value =~ "/enroll/#{link.token}"
      assert html =~ "<svg"
      assert html =~ "Expires"

      assert [entry] = Repo.all(Entry)
      assert entry.user_id == user.id
      assert entry.entity_type == "enrollment_link"
      assert entry.entity_id == link.id
      assert entry.description == "Wannes created a device enrollment link"
    end
  end

  describe "creating an invitation link" do
    test "AUTH-05: has no target user yet, and is logged (AUTH-11)", %{conn: conn, user: user} do
      {:ok, view, _html} = live(conn, ~p"/enrollment-links")

      html = view |> element("#create-invitation-link-button") |> render_click()

      assert [link] = Repo.all(EnrollmentLink)
      assert link.flavour == "user_invitation"
      assert is_nil(link.target_user_id)
      assert html =~ "not yet claimed"

      assert [entry] = Repo.all(Entry)
      assert entry.user_id == user.id
      assert entry.description == "Wannes created an invitation enrollment link"
    end
  end

  describe "revoking a link" do
    test "AUTH-07: removes it from the active list and logs it (AUTH-11)", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/enrollment-links")
      view |> element("#create-device-link-button") |> render_click()

      assert [link] = Repo.all(EnrollmentLink)
      card_id = "links-#{link.id}"
      assert has_element?(view, "##{card_id}")

      view |> element("##{card_id}-revoke") |> render_click()

      refute has_element?(view, "##{card_id}")
      assert has_element?(view, "#enrollment-links-empty")

      assert %EnrollmentLink{revoked_at: %DateTime{}} = Repo.get(EnrollmentLink, link.id)

      entries = Repo.all(Entry)
      assert Enum.any?(entries, &(&1.description == "Wannes revoked a device enrollment link"))
    end

    test "a link created by another user can also be revoked here (AUTH-07)", %{conn: conn} do
      other = insert_user!("Partner")
      {:ok, link} = other |> EnrollmentLink.device_link_changeset() |> Repo.insert()

      {:ok, view, _html} = live(conn, ~p"/enrollment-links")
      card_id = "links-#{link.id}"
      assert has_element?(view, "##{card_id}")

      view |> element("##{card_id}-revoke") |> render_click()

      assert %EnrollmentLink{revoked_at: %DateTime{}} = Repo.get(EnrollmentLink, link.id)
    end
  end

  defp insert_user!(display_name) do
    %User{} |> User.changeset(%{display_name: display_name}) |> Repo.insert!()
  end
end
