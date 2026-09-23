defmodule WeddingPlanner.Accounts.SessionsTest do
  @moduledoc """
  `AUTH-01`/`AUTH-10`: session creation, lookup, sliding expiry and sign-out. Time is
  controlled entirely through the `:now` option (no `Process.sleep/1`, per `AGENTS.md`).
  """
  # async: false — a small mitigation, not a fix, for a pre-existing flake: this repo's
  # full suite already occasionally hits "database busy" under `mix test`'s default
  # concurrency (`max_cases` = `schedulers_online() * 2` against a `pool_size: 5` SQLite
  # connection pool — confirmed by reproducing it on an *unmodified* checkout, with none
  # of this task's files present, roughly 1 run in 4). That's a `config/test.exs`-level
  # capacity question outside this task's boundary (no `config/*` edits). Not adding this
  # file's write-heavy cases to the async pool is the one lever available here.
  use WeddingPlanner.DataCase, async: false

  alias WeddingPlanner.Accounts.Passkey
  alias WeddingPlanner.Accounts.Sessions
  alias WeddingPlanner.Accounts.User
  alias WeddingPlanner.Accounts.UserSession

  @epoch ~U[2026-09-01 12:00:00Z]

  setup do
    user = insert_user!("Wannes")
    passkey = insert_passkey!(user)
    %{user: user, passkey: passkey}
  end

  describe "create_session/3" do
    test "persists a session tied to the user and passkey, returning the raw token", %{
      user: user,
      passkey: passkey
    } do
      assert {:ok, session, token} = Sessions.create_session(user, passkey, now: @epoch)

      assert session.user_id == user.id
      assert session.passkey_id == passkey.id
      assert session.last_used_at == @epoch
      assert is_binary(token)
      assert byte_size(token) == 32
      assert session.token == token
    end

    test "the passkey is optional", %{user: user} do
      assert {:ok, session, _token} = Sessions.create_session(user, nil, now: @epoch)
      assert session.passkey_id == nil
    end

    test "two sessions for the same user get different tokens", %{user: user} do
      {:ok, _s1, token1} = Sessions.create_session(user, nil, now: @epoch)
      {:ok, _s2, token2} = Sessions.create_session(user, nil, now: @epoch)

      refute token1 == token2
    end
  end

  describe "fetch_by_token/2" do
    test "resolves a fresh session, preloaded with its user", %{user: user, passkey: passkey} do
      {:ok, _session, token} = Sessions.create_session(user, passkey, now: @epoch)

      assert {:ok, fetched} = Sessions.fetch_by_token(token, now: @epoch)
      assert fetched.user.id == user.id
    end

    test "an unknown token is rejected" do
      assert Sessions.fetch_by_token(:crypto.strong_rand_bytes(32)) == :error
    end

    ## AUTH-10: sliding expiry — this is the one property that must be provably able to
    ## fail, so each direction gets its own test with a hand-broken assertion checked
    ## first, per the task's verification requirement.

    test "a session used within the 30-day window is accepted and extended", %{user: user} do
      {:ok, _session, token} = Sessions.create_session(user, nil, now: @epoch)

      almost_expired = DateTime.add(@epoch, 29, :day)
      assert {:ok, fetched} = Sessions.fetch_by_token(token, now: almost_expired)
      assert fetched.last_used_at == almost_expired

      # Sliding: a second use, another 29 days later (60 total from creation, which would
      # be expired against the *original* last_used_at), still succeeds because the first
      # fetch already extended the window.
      still_later = DateTime.add(almost_expired, 29, :day)
      assert {:ok, fetched_again} = Sessions.fetch_by_token(token, now: still_later)
      assert fetched_again.last_used_at == still_later
    end

    test "a session unused for more than 30 days is rejected", %{user: user} do
      {:ok, _session, token} = Sessions.create_session(user, nil, now: @epoch)

      just_expired = DateTime.add(@epoch, 30 * 24 * 60 * 60 + 1, :second)
      assert Sessions.fetch_by_token(token, now: just_expired) == :error
    end

    test "exactly the 30-day boundary is still accepted", %{user: user} do
      {:ok, _session, token} = Sessions.create_session(user, nil, now: @epoch)

      boundary = DateTime.add(@epoch, 30 * 24 * 60 * 60, :second)
      assert {:ok, _fetched} = Sessions.fetch_by_token(token, now: boundary)
    end

    test "a rejected (expired) lookup does not extend the session", %{user: user} do
      {:ok, session, token} = Sessions.create_session(user, nil, now: @epoch)

      just_expired = DateTime.add(@epoch, 30 * 24 * 60 * 60 + 1, :second)
      assert Sessions.fetch_by_token(token, now: just_expired) == :error

      reloaded = Repo.get!(UserSession, session.id)
      assert reloaded.last_used_at == @epoch
    end
  end

  describe "expired?/2" do
    test "false within the window, true past it", %{user: user} do
      {:ok, session, _token} = Sessions.create_session(user, nil, now: @epoch)

      refute Sessions.expired?(session, DateTime.add(@epoch, 30 * 24 * 60 * 60, :second))
      assert Sessions.expired?(session, DateTime.add(@epoch, 30 * 24 * 60 * 60 + 1, :second))
    end
  end

  describe "delete_session/1" do
    test "removes the session so the token no longer resolves", %{user: user} do
      {:ok, _session, token} = Sessions.create_session(user, nil, now: @epoch)
      assert :ok = Sessions.delete_session(token)
      assert Sessions.fetch_by_token(token) == :error
    end

    test "deleting an unknown token is a no-op" do
      assert :ok = Sessions.delete_session(:crypto.strong_rand_bytes(32))
    end
  end

  describe "delete_sessions_for_passkey/1 (DR-24, additive)" do
    test "deletes every session opened by that passkey, returning their raw tokens", %{
      user: user,
      passkey: passkey
    } do
      {:ok, _s1, token1} = Sessions.create_session(user, passkey, now: @epoch)
      {:ok, _s2, token2} = Sessions.create_session(user, passkey, now: @epoch)

      tokens = Sessions.delete_sessions_for_passkey(passkey)

      assert Enum.sort(tokens) == Enum.sort([token1, token2])
      assert Sessions.fetch_by_token(token1) == :error
      assert Sessions.fetch_by_token(token2) == :error
    end

    test "leaves sessions opened by a different passkey (or no passkey) untouched", %{
      user: user,
      passkey: passkey
    } do
      other_passkey = insert_passkey!(user)
      {:ok, _s1, doomed_token} = Sessions.create_session(user, passkey, now: @epoch)
      {:ok, _s2, other_token} = Sessions.create_session(user, other_passkey, now: @epoch)
      {:ok, _s3, no_passkey_token} = Sessions.create_session(user, nil, now: @epoch)

      Sessions.delete_sessions_for_passkey(passkey)

      assert {:ok, _} = Sessions.fetch_by_token(other_token)
      assert {:ok, _} = Sessions.fetch_by_token(no_passkey_token)
      assert Sessions.fetch_by_token(doomed_token) == :error
    end

    test "a passkey with no sessions returns an empty list", %{passkey: passkey} do
      assert Sessions.delete_sessions_for_passkey(passkey) == []
    end
  end

  defp insert_user!(display_name) do
    %User{} |> User.changeset(%{display_name: display_name}) |> Repo.insert!()
  end

  defp insert_passkey!(user) do
    %Passkey{user_id: user.id, sign_count: 0}
    |> Passkey.registration_changeset(%{
      credential_id: :crypto.strong_rand_bytes(16),
      public_key: Passkey.encode_cose_key(%{1 => 2, 3 => -7, -1 => 1, -2 => <<1, 2, 3>>}),
      name: "Laptop",
      registered_at: @epoch
    })
    |> Repo.insert!()
  end
end
