defmodule WeddingPlanner.Accounts.PasskeysTest do
  @moduledoc """
  `AUTH-08`, `AUTH-11`, `DR-24`: passkey listing, scoping, renaming and revocation
  (including the atomic last-passkey guard and the session cleanup a revoke triggers).
  The concurrent two-tabs-racing-the-last-two-passkeys case is proven separately, over
  real independent connections, in `PasskeysConcurrencyTest` — see that module's
  moduledoc for why the sandbox can't be trusted for that specific claim.
  """
  # async: false, matching `SessionsTest`'s own note: this repo's suite occasionally hits
  # "database busy" under the default test concurrency: not adding this write-heavy,
  # transaction-using file to the async pool is the mitigation available within this
  # task's boundary (no config/*.exs edits).
  use WeddingPlanner.DataCase, async: false

  alias WeddingPlanner.Accounts.Passkey
  alias WeddingPlanner.Accounts.Passkeys
  alias WeddingPlanner.Accounts.Scope
  alias WeddingPlanner.Accounts.Sessions
  alias WeddingPlanner.Accounts.User
  alias WeddingPlanner.Accounts.UserSession
  alias WeddingPlanner.Log.Entry

  @epoch ~U[2026-09-01 12:00:00Z]

  setup do
    user = insert_user!("Wannes")
    other = insert_user!("Partner")
    %{user: user, scope: Scope.for_user(user), other: other}
  end

  describe "list_for_user/1" do
    test "returns only this user's passkeys, oldest registered first", %{user: user, other: other} do
      _other_pk = insert_passkey!(other, "Other's phone", @epoch)
      newer = insert_passkey!(user, "Newer", DateTime.add(@epoch, 3600))
      older = insert_passkey!(user, "Older", @epoch)

      assert Passkeys.list_for_user(user) == [older, newer]
    end
  end

  describe "count_for_user/1" do
    test "counts only this user's passkeys", %{user: user, other: other} do
      insert_passkey!(user, "A", @epoch)
      insert_passkey!(user, "B", @epoch)
      insert_passkey!(other, "C", @epoch)

      assert Passkeys.count_for_user(user) == 2
      assert Passkeys.count_for_user(other) == 1
    end
  end

  describe "get_own/2" do
    test "returns the passkey when it belongs to the given user", %{user: user} do
      pk = insert_passkey!(user, "Laptop", @epoch)
      assert Passkeys.get_own(user, pk.id) == pk
    end

    test "returns nil for another user's passkey (AUTH-08: own passkeys only)", %{
      user: user,
      other: other
    } do
      pk = insert_passkey!(other, "Not yours", @epoch)
      assert Passkeys.get_own(user, pk.id) == nil
    end

    test "returns nil for a nonexistent id", %{user: user} do
      assert Passkeys.get_own(user, -1) == nil
    end
  end

  describe "rename/3" do
    test "persists the new name and logs the change (AUTH-08, AUTH-11)", %{
      user: user,
      scope: scope
    } do
      pk = insert_passkey!(user, "New passkey", @epoch)

      assert {:ok, renamed} = Passkeys.rename(scope, pk, %{"name" => "Wannes' phone"})
      assert renamed.name == "Wannes' phone"
      assert Repo.get!(Passkey, pk.id).name == "Wannes' phone"

      assert [entry] = Repo.all(Entry)
      assert entry.entity_type == "passkey"
      assert entry.entity_id == pk.id
      assert entry.description == "Wannes renamed passkey 'New passkey' → 'Wannes' phone'"
    end

    test "rejects a blank name and logs nothing", %{user: user, scope: scope} do
      pk = insert_passkey!(user, "New passkey", @epoch)

      assert {:error, changeset} = Passkeys.rename(scope, pk, %{"name" => ""})
      assert "can't be blank" in errors_on(changeset).name
      assert Repo.all(Entry) == []
    end

    test "resubmitting the same name is a no-op save and logs nothing", %{
      user: user,
      scope: scope
    } do
      pk = insert_passkey!(user, "Laptop", @epoch)

      assert {:ok, _} = Passkeys.rename(scope, pk, %{"name" => "Laptop"})
      assert Repo.all(Entry) == []
    end
  end

  describe "revoke/2" do
    test "deletes a non-last passkey and logs it (AUTH-08, AUTH-11)", %{
      user: user,
      scope: scope
    } do
      keep = insert_passkey!(user, "Laptop", @epoch)
      doomed = insert_passkey!(user, "Old phone", @epoch)

      assert {:ok, %{passkey: revoked, session_tokens: []}} = Passkeys.revoke(scope, doomed)
      assert revoked.id == doomed.id

      assert Repo.get(Passkey, doomed.id) == nil
      assert Repo.get(Passkey, keep.id) != nil

      assert [entry] = Repo.all(Entry)
      assert entry.entity_type == "passkey"
      assert entry.entity_id == doomed.id
      assert entry.description == "Wannes revoked passkey 'Old phone'"
    end

    test "refuses to delete the user's last remaining passkey", %{user: user, scope: scope} do
      only = insert_passkey!(user, "Only one", @epoch)

      assert Passkeys.revoke(scope, only) == {:error, :last_passkey}
      assert Repo.get(Passkey, only.id) != nil
      assert Repo.all(Entry) == []
    end

    test "DR-24: deletes every session opened by the revoked passkey, returning their tokens", %{
      user: user,
      scope: scope
    } do
      keep_pk = insert_passkey!(user, "Laptop", @epoch)
      doomed_pk = insert_passkey!(user, "Old phone", @epoch)

      {:ok, _session1, token1} = Sessions.create_session(user, doomed_pk, now: @epoch)
      {:ok, _session2, token2} = Sessions.create_session(user, doomed_pk, now: @epoch)
      {:ok, kept_session, kept_token} = Sessions.create_session(user, keep_pk, now: @epoch)

      assert {:ok, %{session_tokens: tokens}} = Passkeys.revoke(scope, doomed_pk)
      assert Enum.sort(tokens) == Enum.sort([token1, token2])

      # The revoked passkey's own sessions are gone.
      assert Sessions.fetch_by_token(token1) == :error
      assert Sessions.fetch_by_token(token2) == :error

      # A session opened by a *different* passkey (still belonging to the same user)
      # survives untouched.
      assert {:ok, fetched} = Sessions.fetch_by_token(kept_token)
      assert fetched.id == kept_session.id
    end

    test "DR-24: does not touch another passkey's sessions, including another user's", %{
      user: user,
      scope: scope,
      other: other
    } do
      other_pk = insert_passkey!(other, "Partner's phone", @epoch)
      {:ok, _session, other_token} = Sessions.create_session(other, other_pk, now: @epoch)

      doomed = insert_passkey!(user, "Old phone", @epoch)
      _keep = insert_passkey!(user, "Laptop", @epoch)

      assert {:ok, _} = Passkeys.revoke(scope, doomed)
      assert {:ok, _} = Sessions.fetch_by_token(other_token)
    end

    test "a refused (last-passkey) revoke does not touch its sessions", %{
      user: user,
      scope: scope
    } do
      only = insert_passkey!(user, "Only one", @epoch)
      {:ok, session, token} = Sessions.create_session(user, only, now: @epoch)

      assert Passkeys.revoke(scope, only) == {:error, :last_passkey}
      assert {:ok, _} = Sessions.fetch_by_token(token)
      assert Repo.get(UserSession, session.id) != nil
    end
  end

  defp insert_user!(display_name) do
    %User{} |> User.changeset(%{display_name: display_name}) |> Repo.insert!()
  end

  defp insert_passkey!(user, name, registered_at) do
    %Passkey{user_id: user.id, sign_count: 0}
    |> Passkey.registration_changeset(%{
      credential_id: :crypto.strong_rand_bytes(16),
      public_key: Passkey.encode_cose_key(%{1 => 2, 3 => -7, -1 => 1, -2 => <<1, 2, 3>>}),
      name: name,
      registered_at: registered_at
    })
    |> Repo.insert!()
  end
end
