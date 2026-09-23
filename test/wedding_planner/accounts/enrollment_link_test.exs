defmodule WeddingPlanner.Accounts.EnrollmentLinkTest do
  @moduledoc """
  AUTH-04 through AUTH-09: the three enrollment link flavours, with the right fields
  present and absent for each, and NFR-21 (moments are UTC).
  """
  use WeddingPlanner.DataCase, async: true

  alias WeddingPlanner.Accounts.EnrollmentLink
  alias WeddingPlanner.Accounts.User

  setup do
    {:ok, issuer} = %User{} |> User.changeset(%{display_name: "Wannes"}) |> Repo.insert()
    {:ok, target} = %User{} |> User.changeset(%{display_name: "Partner"}) |> Repo.insert()
    %{issuer: issuer, target: target}
  end

  test "AUTH-04: a device link has the same issuing and target user", %{issuer: issuer} do
    {:ok, link} =
      EnrollmentLink.device_link_changeset(issuer) |> Repo.insert()

    assert link.flavour == "device"
    assert link.issuing_user_id == issuer.id
    assert link.target_user_id == issuer.id
    assert is_binary(link.token) and byte_size(link.token) > 0
  end

  test "AUTH-05: a user-invitation link has an issuing user and no target user yet", %{
    issuer: issuer
  } do
    {:ok, link} =
      EnrollmentLink.user_invitation_link_changeset(issuer) |> Repo.insert()

    assert link.flavour == "user_invitation"
    assert link.issuing_user_id == issuer.id
    assert is_nil(link.target_user_id)
  end

  test "AUTH-05: the target user can be assigned once the link is redeemed", %{
    issuer: issuer,
    target: target
  } do
    {:ok, link} = EnrollmentLink.user_invitation_link_changeset(issuer) |> Repo.insert()

    {:ok, updated} =
      link |> EnrollmentLink.assign_target_user_changeset(target) |> Repo.update()

    assert updated.target_user_id == target.id
  end

  test "AUTH-09: a recovery link has a target user and no issuing user", %{target: target} do
    {:ok, link} = EnrollmentLink.recovery_link_changeset(target) |> Repo.insert()

    assert link.flavour == "recovery"
    assert is_nil(link.issuing_user_id)
    assert link.target_user_id == target.id
  end

  test "tokens are unique", %{issuer: issuer} do
    {:ok, _first} = EnrollmentLink.device_link_changeset(issuer) |> Repo.insert()
    {:ok, second} = EnrollmentLink.device_link_changeset(issuer) |> Repo.insert()

    # Each builder generates its own token, so two links never collide in practice, but
    # forcing a collision proves the DB constraint (and thus the lookup guarantee) is
    # actually there rather than assumed.
    changeset = EnrollmentLink.device_link_changeset(issuer)
    duplicate = Ecto.Changeset.put_change(changeset, :token, second.token)

    assert {:error, result} = Repo.insert(duplicate)
    assert "has already been taken" in errors_on(result).token
  end

  test "expiry defaults to AUTH-06's 15 minutes and is UTC (NFR-21)", %{issuer: issuer} do
    before = DateTime.utc_now()
    {:ok, link} = EnrollmentLink.device_link_changeset(issuer) |> Repo.insert()

    assert %DateTime{time_zone: "Etc/UTC"} = link.expires_at
    seconds_until_expiry = DateTime.diff(link.expires_at, before, :second)
    assert_in_delta seconds_until_expiry, EnrollmentLink.default_ttl_seconds(), 5
  end

  test "expiry can be overridden, e.g. to build an already-expired link for tests", %{
    issuer: issuer
  } do
    already_expired =
      DateTime.utc_now() |> DateTime.add(-1, :second) |> DateTime.truncate(:second)

    {:ok, link} =
      EnrollmentLink.device_link_changeset(issuer, %{expires_at: already_expired})
      |> Repo.insert()

    assert DateTime.compare(link.expires_at, DateTime.utc_now()) == :lt
  end

  test "used_at and revoked_at are UTC once set (NFR-21)", %{issuer: issuer} do
    {:ok, link} = EnrollmentLink.device_link_changeset(issuer) |> Repo.insert()
    assert is_nil(link.used_at)
    assert is_nil(link.revoked_at)

    now = DateTime.utc_now() |> DateTime.truncate(:second)
    {:ok, used} = link |> EnrollmentLink.use_changeset(now) |> Repo.update()
    assert %DateTime{time_zone: "Etc/UTC"} = used.used_at

    {:ok, link2} = EnrollmentLink.device_link_changeset(issuer) |> Repo.insert()
    {:ok, revoked} = link2 |> EnrollmentLink.revoke_changeset(now) |> Repo.update()
    assert %DateTime{time_zone: "Etc/UTC"} = revoked.revoked_at
  end

  test "token, flavour and user references cannot be set through cast", %{issuer: issuer} do
    changeset =
      EnrollmentLink.device_link_changeset(issuer, %{
        token: "attacker-supplied",
        flavour: "recovery",
        issuing_user_id: issuer.id + 1000,
        target_user_id: issuer.id + 1000
      })

    refute changeset.changes[:token] == "attacker-supplied"
    assert Ecto.Changeset.get_field(changeset, :flavour) == "device"
    assert Ecto.Changeset.get_field(changeset, :issuing_user_id) == issuer.id
    assert Ecto.Changeset.get_field(changeset, :target_user_id) == issuer.id
  end
end
