defmodule WeddingPlanner.Accounts.PasskeyTest do
  @moduledoc """
  AUTH-02, AUTH-08. The COSE-key-in-CBOR-BLOB storage decision
  (`.claude/dr4-webauthn/findings.md`) is the load-bearing thing to prove here: Wax
  returns the COSE public key as a map with *negative integer keys*, which neither JSON
  nor Ecto's `:map` can round-trip. This test proves the CBOR-encoded blob comes back
  byte-identical, and that the decoded map is exactly what went in, negative keys and all.
  """
  use WeddingPlanner.DataCase, async: true

  alias WeddingPlanner.Accounts.Passkey
  alias WeddingPlanner.Accounts.User

  setup do
    {:ok, user} = %User{} |> User.changeset(%{display_name: "Wannes"}) |> Repo.insert()
    %{user: user}
  end

  defp registered_at, do: DateTime.utc_now() |> DateTime.truncate(:second)

  test "a CBOR-encoded COSE key round-trips through the BLOB column byte-identical", %{
    user: user
  } do
    # A real COSE_Key map shape as Wax returns it: negative integer keys, an embedded
    # binary (the EC point), and a mix of positive and negative-valued integers.
    cose_key = %{
      1 => 2,
      3 => -7,
      -1 => 1,
      -2 => :crypto.strong_rand_bytes(32),
      -3 => :crypto.strong_rand_bytes(32)
    }

    public_key_blob = Passkey.encode_cose_key(cose_key)

    {:ok, stored} =
      %Passkey{user_id: user.id, sign_count: 0}
      |> Passkey.registration_changeset(%{
        credential_id: :crypto.strong_rand_bytes(32),
        public_key: public_key_blob,
        aaguid: :crypto.strong_rand_bytes(16),
        transports: ["internal", "hybrid"],
        name: "Wannes' phone",
        registered_at: registered_at()
      })
      |> Repo.insert()

    reloaded = Repo.get!(Passkey, stored.id)

    # The blob itself must be byte-identical: no re-encoding, no mangling into UTF-8 text.
    assert reloaded.public_key == public_key_blob
    assert is_binary(reloaded.public_key)

    # And it must decode back into the exact COSE map that went in.
    assert Passkey.cose_key(reloaded) == cose_key
  end

  test "a credential id and aaguid with embedded NULs and invalid UTF-8 survive", %{user: user} do
    nasty = <<0, 255, 254, 0, 0, 128, 10, 13, 26, 39, 34, 92>>

    {:ok, stored} =
      %Passkey{user_id: user.id, sign_count: 0}
      |> Passkey.registration_changeset(%{
        credential_id: nasty,
        public_key: Passkey.encode_cose_key(%{1 => 2, 3 => -7, -1 => 1, -2 => nasty}),
        aaguid: nasty,
        name: "nasty",
        registered_at: registered_at()
      })
      |> Repo.insert()

    reloaded = Repo.get!(Passkey, stored.id)
    assert reloaded.credential_id == nasty
    assert reloaded.aaguid == nasty
    assert Passkey.cose_key(reloaded)[-2] == nasty
  end

  test "a credential id can be looked up by its raw bytes (the login path needs this)", %{
    user: user
  } do
    cred_id = :crypto.strong_rand_bytes(32)

    {:ok, _} =
      %Passkey{user_id: user.id, sign_count: 0}
      |> Passkey.registration_changeset(%{
        credential_id: cred_id,
        public_key: Passkey.encode_cose_key(%{1 => 2, 3 => -7}),
        name: "k",
        registered_at: registered_at()
      })
      |> Repo.insert()

    import Ecto.Query
    assert %Passkey{} = Repo.one(from p in Passkey, where: p.credential_id == ^cred_id)
  end

  test "the credential id unique index rejects a duplicate", %{user: user} do
    {:ok, other_user} = %User{} |> User.changeset(%{display_name: "Other"}) |> Repo.insert()
    cred_id = :crypto.strong_rand_bytes(32)

    attrs = %{
      credential_id: cred_id,
      public_key: Passkey.encode_cose_key(%{1 => 2, 3 => -7}),
      name: "k",
      registered_at: registered_at()
    }

    {:ok, _} =
      %Passkey{user_id: user.id, sign_count: 0}
      |> Passkey.registration_changeset(attrs)
      |> Repo.insert()

    assert {:error, changeset} =
             %Passkey{user_id: other_user.id, sign_count: 0}
             |> Passkey.registration_changeset(attrs)
             |> Repo.insert()

    assert "has already been taken" in errors_on(changeset).credential_id
  end

  test "AUTH-08: the name is editable and last-used is recorded on use", %{user: user} do
    {:ok, passkey} =
      %Passkey{user_id: user.id, sign_count: 0}
      |> Passkey.registration_changeset(%{
        credential_id: :crypto.strong_rand_bytes(32),
        public_key: Passkey.encode_cose_key(%{1 => 2, 3 => -7}),
        name: "New passkey",
        registered_at: registered_at()
      })
      |> Repo.insert()

    {:ok, renamed} =
      passkey |> Passkey.rename_changeset(%{name: "Wannes' phone"}) |> Repo.update()

    assert renamed.name == "Wannes' phone"

    now = registered_at()
    {:ok, used} = renamed |> Passkey.usage_changeset(7, now) |> Repo.update()
    assert used.sign_count == 7
    assert DateTime.compare(used.last_used_at, now) == :eq
  end

  test "sign_count and user_id are not settable through cast", %{user: user} do
    changeset =
      %Passkey{user_id: user.id, sign_count: 0}
      |> Passkey.registration_changeset(%{
        credential_id: :crypto.strong_rand_bytes(32),
        public_key: Passkey.encode_cose_key(%{1 => 2, 3 => -7}),
        name: "k",
        registered_at: registered_at(),
        # Attempted mass-assignment: neither of these must be picked up by cast.
        sign_count: 99,
        user_id: user.id + 1000
      })

    refute Ecto.Changeset.changed?(changeset, :sign_count)
    refute Ecto.Changeset.changed?(changeset, :user_id)
  end

  test "registration moment is UTC (NFR-21)", %{user: user} do
    {:ok, stored} =
      %Passkey{user_id: user.id, sign_count: 0}
      |> Passkey.registration_changeset(%{
        credential_id: :crypto.strong_rand_bytes(32),
        public_key: Passkey.encode_cose_key(%{1 => 2, 3 => -7}),
        name: "k",
        registered_at: registered_at()
      })
      |> Repo.insert()

    assert %DateTime{time_zone: "Etc/UTC"} = stored.registered_at
    assert is_nil(stored.last_used_at)
  end
end
