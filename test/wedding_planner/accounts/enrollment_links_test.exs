defmodule WeddingPlanner.Accounts.EnrollmentLinksTest do
  @moduledoc """
  `AUTH-04` through `AUTH-07`: link creation, listing, redemption validity and
  revocation at the context level. `claim/2`'s single-attempt behaviour is covered here;
  its behaviour under real concurrent connections is covered separately by
  `EnrollmentLinksConcurrencyTest`, mirroring how `SetupTest` and `SetupConcurrencyTest`
  split the same concern for `DR-22`.
  """
  use WeddingPlanner.DataCase, async: true

  alias WeddingPlanner.Accounts.EnrollmentLink
  alias WeddingPlanner.Accounts.EnrollmentLinks
  alias WeddingPlanner.Accounts.User

  setup do
    {:ok, issuer} = %User{} |> User.changeset(%{display_name: "Wannes"}) |> Repo.insert()
    {:ok, target} = %User{} |> User.changeset(%{display_name: "Partner"}) |> Repo.insert()
    %{issuer: issuer, target: target}
  end

  describe "create_device_link/1" do
    test "AUTH-04: issues a link for the same user, with the right fields", %{issuer: issuer} do
      {:ok, link} = EnrollmentLinks.create_device_link(issuer)

      assert link.flavour == "device"
      assert link.issuing_user_id == issuer.id
      assert link.target_user_id == issuer.id
      assert is_binary(link.token) and byte_size(link.token) > 0
      assert DateTime.compare(link.expires_at, DateTime.utc_now()) == :gt
    end
  end

  describe "create_invitation_link/1" do
    test "AUTH-05: issues a link with no target user yet", %{issuer: issuer} do
      {:ok, link} = EnrollmentLinks.create_invitation_link(issuer)

      assert link.flavour == "user_invitation"
      assert link.issuing_user_id == issuer.id
      assert is_nil(link.target_user_id)
    end
  end

  describe "list_active_links/1" do
    test "lists unused, unexpired, unrevoked links newest first, every flavour", %{
      issuer: issuer,
      target: target
    } do
      {:ok, device} = EnrollmentLinks.create_device_link(issuer)
      {:ok, invitation} = EnrollmentLinks.create_invitation_link(issuer)
      {:ok, recovery} = EnrollmentLink.recovery_link_changeset(target) |> Repo.insert()

      ids = EnrollmentLinks.list_active_links() |> Enum.map(& &1.id)

      assert ids == [recovery.id, invitation.id, device.id]
    end

    test "excludes used, expired and revoked links", %{issuer: issuer} do
      now = DateTime.utc_now() |> DateTime.truncate(:second)
      expired_at = DateTime.add(now, -1, :second)

      {:ok, used} = EnrollmentLinks.create_device_link(issuer)
      {:ok, used} = used |> EnrollmentLink.use_changeset(now) |> Repo.update()

      {:ok, expired} =
        EnrollmentLink.device_link_changeset(issuer, %{expires_at: expired_at}) |> Repo.insert()

      {:ok, revoked} = EnrollmentLinks.create_device_link(issuer)
      {:ok, revoked} = revoked |> EnrollmentLink.revoke_changeset(now) |> Repo.update()

      {:ok, active} = EnrollmentLinks.create_device_link(issuer)

      ids = EnrollmentLinks.list_active_links() |> Enum.map(& &1.id)

      assert ids == [active.id]
      refute used.id in ids
      refute expired.id in ids
      refute revoked.id in ids
    end

    test "preloads issuing and target users", %{issuer: issuer} do
      {:ok, _link} = EnrollmentLinks.create_device_link(issuer)

      [link] = EnrollmentLinks.list_active_links()

      assert %User{} = link.issuing_user
      assert %User{} = link.target_user
    end
  end

  describe "revoke/2" do
    test "AUTH-07: revokes an unused link", %{issuer: issuer} do
      {:ok, link} = EnrollmentLinks.create_device_link(issuer)
      now = DateTime.utc_now() |> DateTime.truncate(:second)

      {:ok, revoked} = EnrollmentLinks.revoke(link, now)

      assert revoked.revoked_at == now
      assert EnrollmentLinks.list_active_links() == []
    end

    test "refuses to revoke an already-used link", %{issuer: issuer} do
      now = DateTime.utc_now() |> DateTime.truncate(:second)
      {:ok, link} = EnrollmentLinks.create_device_link(issuer)
      {:ok, used} = link |> EnrollmentLink.use_changeset(now) |> Repo.update()

      assert {:error, :already_used} = EnrollmentLinks.revoke(used, now)
    end

    test "refuses to revoke an already-revoked link", %{issuer: issuer} do
      now = DateTime.utc_now() |> DateTime.truncate(:second)
      {:ok, link} = EnrollmentLinks.create_device_link(issuer)
      {:ok, revoked} = EnrollmentLinks.revoke(link, now)

      assert {:error, :already_revoked} = EnrollmentLinks.revoke(revoked, now)
    end
  end

  describe "fetch_for_redemption/2" do
    test "returns the link for a valid, unexpired token", %{issuer: issuer} do
      {:ok, link} = EnrollmentLinks.create_device_link(issuer)

      assert {:ok, fetched} = EnrollmentLinks.fetch_for_redemption(link.token)
      assert fetched.id == link.id
      assert %User{} = fetched.target_user
    end

    test "rejects an unknown token" do
      assert {:error, :not_found} = EnrollmentLinks.fetch_for_redemption("does-not-exist")
    end

    test "AUTH-06: rejects a used link", %{issuer: issuer} do
      now = DateTime.utc_now() |> DateTime.truncate(:second)
      {:ok, link} = EnrollmentLinks.create_device_link(issuer)
      {:ok, used} = link |> EnrollmentLink.use_changeset(now) |> Repo.update()

      assert {:error, :used} = EnrollmentLinks.fetch_for_redemption(used.token)
    end

    test "AUTH-06: rejects an expired link", %{issuer: issuer} do
      expired_at =
        DateTime.utc_now() |> DateTime.add(-1, :second) |> DateTime.truncate(:second)

      {:ok, link} =
        EnrollmentLink.device_link_changeset(issuer, %{expires_at: expired_at}) |> Repo.insert()

      assert {:error, :expired} = EnrollmentLinks.fetch_for_redemption(link.token)
    end

    test "AUTH-07: rejects a revoked link", %{issuer: issuer} do
      now = DateTime.utc_now() |> DateTime.truncate(:second)
      {:ok, link} = EnrollmentLinks.create_device_link(issuer)
      {:ok, revoked} = EnrollmentLinks.revoke(link, now)

      assert {:error, :revoked} = EnrollmentLinks.fetch_for_redemption(revoked.token)
    end
  end

  describe "claim/2" do
    test "succeeds once and fails on a second attempt (single-use)", %{issuer: issuer} do
      {:ok, link} = EnrollmentLinks.create_device_link(issuer)
      now = DateTime.utc_now() |> DateTime.truncate(:second)

      assert :ok = EnrollmentLinks.claim(link, now)
      assert :error = EnrollmentLinks.claim(link, now)

      assert {:error, :used} = EnrollmentLinks.fetch_for_redemption(link.token)
    end

    test "fails against a revoked link", %{issuer: issuer} do
      now = DateTime.utc_now() |> DateTime.truncate(:second)
      {:ok, link} = EnrollmentLinks.create_device_link(issuer)
      {:ok, revoked} = EnrollmentLinks.revoke(link, now)

      assert :error = EnrollmentLinks.claim(revoked, now)
    end

    test "fails against an expired link", %{issuer: issuer} do
      expired_at =
        DateTime.utc_now() |> DateTime.add(-1, :second) |> DateTime.truncate(:second)

      {:ok, link} =
        EnrollmentLink.device_link_changeset(issuer, %{expires_at: expired_at}) |> Repo.insert()

      assert :error =
               EnrollmentLinks.claim(link, DateTime.utc_now() |> DateTime.truncate(:second))
    end
  end

  describe "flavour_label/1" do
    test "labels each flavour", %{issuer: issuer, target: target} do
      {:ok, device} = EnrollmentLinks.create_device_link(issuer)
      {:ok, invitation} = EnrollmentLinks.create_invitation_link(issuer)
      {:ok, recovery} = EnrollmentLink.recovery_link_changeset(target) |> Repo.insert()

      assert EnrollmentLinks.flavour_label(device) == "device"
      assert EnrollmentLinks.flavour_label(invitation) == "invitation"
      assert EnrollmentLinks.flavour_label(recovery) == "recovery"
    end
  end
end
