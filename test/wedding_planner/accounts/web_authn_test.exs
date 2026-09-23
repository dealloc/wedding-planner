defmodule WeddingPlanner.Accounts.WebAuthnTest do
  @moduledoc """
  AUTH-02: the WebAuthn ceremonies, driven end to end by a spec-built software
  authenticator (`WeddingPlanner.SoftwareAuthenticator`) against the real SQLite schema.

  The negative cases are the point. Each rejection test asserts the *specific* reason, so
  it cannot pass because a different check happened to fail first, and each one also
  asserts that nothing was persisted or updated.
  """
  use WeddingPlanner.DataCase, async: true

  alias WeddingPlanner.Accounts.Passkey
  alias WeddingPlanner.Accounts.User
  alias WeddingPlanner.Accounts.WebAuthn
  alias WeddingPlanner.SoftwareAuthenticator

  setup do
    %{user: insert_user!("Wannes")}
  end

  describe "challenge timeout" do
    test "is set explicitly to five minutes rather than Wax's 120-second default" do
      assert WebAuthn.challenge_timeout_seconds() == 300

      {registration, creation_options} = WebAuthn.begin_registration(insert_user!("Timeout"))
      {authentication, request_options} = WebAuthn.begin_authentication()

      assert registration.timeout == 300
      assert authentication.timeout == 300

      # The browser is told the same window, in milliseconds.
      assert creation_options.timeout == 300_000
      assert request_options.timeout == 300_000
    end

    test "a challenge is still accepted shortly before the timeout elapses", %{user: user} do
      {_passkey, authenticator} = register!(user)

      {challenge, options} = WebAuthn.begin_authentication()
      {_authenticator, params} = SoftwareAuthenticator.get(authenticator, options)

      # 290 s: well past Wax's 120 s default, still inside our 300 s.
      challenge = backdate(challenge, 290)

      assert {:ok, %{user: %User{id: id}}} = WebAuthn.finish_authentication(challenge, params)
      assert id == user.id
    end
  end

  describe "begin_registration/1" do
    test "asks for a discoverable, user-verified credential: a passkey, not a second factor",
         %{user: user} do
      {challenge, options} = WebAuthn.begin_registration(user)

      assert challenge.type == :attestation
      assert challenge.user_verification == "required"
      assert challenge.attestation == "none"
      assert byte_size(challenge.bytes) == 32

      assert options.authenticatorSelection == %{
               residentKey: "required",
               requireResidentKey: true,
               userVerification: "required"
             }

      assert options.attestation == "none"
      assert Enum.map(options.pubKeyCredParams, & &1.alg) == [-7, -257]
      assert Enum.all?(options.pubKeyCredParams, &(&1.type == "public-key"))

      # Every ArrayBuffer travels as unpadded base64url.
      assert Base.url_decode64!(options.challenge, padding: false) == challenge.bytes
      refute options.challenge =~ "="

      assert Base.url_decode64!(options.user.id, padding: false) == WebAuthn.user_handle(user)
      assert options.user.name == "Wannes"
      assert options.user.displayName == "Wannes"
      assert options.excludeCredentials == []
    end

    test "takes origin and rp_id from config :wax_, never from the module", %{user: user} do
      {challenge, options} = WebAuthn.begin_registration(user)

      configured_origin = Application.fetch_env!(:wax_, :origin)

      configured_rp_id =
        case Application.fetch_env!(:wax_, :rp_id) do
          :auto -> URI.parse(configured_origin).host
          rp_id -> rp_id
        end

      assert challenge.origin == configured_origin
      assert challenge.rp_id == configured_rp_id
      assert options.rp.id == configured_rp_id

      {auth_challenge, auth_options} = WebAuthn.begin_authentication()
      assert auth_challenge.origin == configured_origin
      assert auth_options.rpId == configured_rp_id
    end

    test "excludes the user's existing credentials, and only theirs", %{user: user} do
      {first, _} = register!(user)
      {second, _} = register!(user)
      {_other, _} = register!(insert_user!("Partner"))

      {_challenge, options} = WebAuthn.begin_registration(user)

      excluded =
        Enum.map(options.excludeCredentials, fn %{type: "public-key", id: id} ->
          Base.url_decode64!(id, padding: false)
        end)

      assert Enum.sort(excluded) == Enum.sort([first.credential_id, second.credential_id])
    end

    test "the user handle is the row id as 8 big-endian bytes", %{user: user} do
      assert WebAuthn.user_handle(user) == <<user.id::unsigned-big-integer-size(64)>>
    end
  end

  describe "begin_authentication/0" do
    test "is usernameless: no allowCredentials at all" do
      {challenge, options} = WebAuthn.begin_authentication()

      assert challenge.type == :authentication
      assert challenge.allow_credentials == []
      assert challenge.user_verification == "required"
      refute Map.has_key?(options, :allowCredentials)
      assert options.userVerification == "required"
      assert Base.url_decode64!(options.challenge, padding: false) == challenge.bytes
    end
  end

  describe "round trip against a software authenticator" do
    test "registration persists a passkey whose stored key verifies a later assertion",
         %{user: user} do
      {challenge, options} = WebAuthn.begin_registration(user)
      {authenticator, params} = SoftwareAuthenticator.create(options)
      registered_at = ~U[2026-09-23 10:00:00Z]

      assert {:ok, %Passkey{} = passkey} =
               WebAuthn.finish_registration(user, challenge, params,
                 name: "Wannes' laptop",
                 now: registered_at
               )

      # Store: exactly what AUTH-08 needs, read back from SQLite rather than trusted
      # from the returned struct.
      stored = Repo.get!(Passkey, passkey.id)
      assert stored.user_id == user.id
      assert stored.credential_id == authenticator.credential_id
      assert stored.aaguid == authenticator.aaguid
      assert stored.transports == ["internal", "hybrid"]
      assert stored.sign_count == 0
      assert stored.name == "Wannes' laptop"
      assert stored.registered_at == registered_at
      assert stored.last_used_at == nil

      # Load and decode: the CBOR blob comes back as the exact COSE map, negative keys
      # and raw coordinate bytes intact.
      assert Passkey.cose_key(stored) == authenticator.cose_key

      # Verify: a usernameless login succeeds using only the key as loaded from the DB.
      {auth_challenge, auth_options} = WebAuthn.begin_authentication()
      {_authenticator, assertion} = SoftwareAuthenticator.get(authenticator, auth_options)
      used_at = ~U[2026-09-23 11:00:00Z]

      assert {:ok, %{user: logged_in, passkey: used}} =
               WebAuthn.finish_authentication(auth_challenge, assertion, now: used_at)

      assert logged_in.id == user.id
      assert used.id == passkey.id

      reloaded = Repo.get!(Passkey, passkey.id)
      assert reloaded.sign_count == 1
      assert reloaded.last_used_at == used_at
    end

    test "the counter advances on every successful login", %{user: user} do
      {passkey, authenticator} = register!(user)

      authenticator =
        Enum.reduce(1..3, authenticator, fn expected, authenticator ->
          {challenge, options} = WebAuthn.begin_authentication()
          {authenticator, params} = SoftwareAuthenticator.get(authenticator, options)
          assert {:ok, _} = WebAuthn.finish_authentication(challenge, params)
          assert Repo.get!(Passkey, passkey.id).sign_count == expected
          authenticator
        end)

      assert authenticator.sign_count == 3
    end

    test "an authenticator that always reports 0 may log in repeatedly", %{user: user} do
      {passkey, authenticator} = register!(user, counter: :zero)

      for _ <- 1..2 do
        {challenge, options} = WebAuthn.begin_authentication()
        {_authenticator, params} = SoftwareAuthenticator.get(authenticator, options)
        assert {:ok, _} = WebAuthn.finish_authentication(challenge, params)
      end

      assert Repo.get!(Passkey, passkey.id).sign_count == 0
    end

    test "the user is resolved from the user handle, among several users", %{user: user} do
      partner = insert_user!("Partner")
      {_, mine} = register!(user)
      {_, theirs} = register!(partner)

      for {authenticator, expected} <- [{mine, user}, {theirs, partner}] do
        {challenge, options} = WebAuthn.begin_authentication()
        {_authenticator, params} = SoftwareAuthenticator.get(authenticator, options)
        assert {:ok, %{user: resolved}} = WebAuthn.finish_authentication(challenge, params)
        assert resolved.id == expected.id
      end
    end
  end

  describe "finish_registration/4 rejects" do
    test "a response from the wrong origin", %{user: user} do
      {challenge, options} = WebAuthn.begin_registration(user)
      {_a, params} = SoftwareAuthenticator.create(options, origin: "https://evil.example")

      assert {:error, %Wax.InvalidClientDataError{reason: :origin_mismatch}} =
               WebAuthn.finish_registration(user, challenge, params, name: "x")

      assert passkey_count() == 0
    end

    test "a response for the wrong rp_id", %{user: user} do
      {challenge, options} = WebAuthn.begin_registration(user)
      {_a, params} = SoftwareAuthenticator.create(options, rp_id: "evil.example")

      assert {:error, %Wax.InvalidClientDataError{reason: :rp_id_mismatch}} =
               WebAuthn.finish_registration(user, challenge, params, name: "x")

      assert passkey_count() == 0
    end

    test "an expired challenge", %{user: user} do
      {challenge, options} = WebAuthn.begin_registration(user)
      {_a, params} = SoftwareAuthenticator.create(options)

      assert {:error, %Wax.ExpiredChallengeError{}} =
               WebAuthn.finish_registration(user, expire(challenge), params, name: "x")

      assert passkey_count() == 0
    end

    test "a response answering a different challenge", %{user: user} do
      {_first, first_options} = WebAuthn.begin_registration(user)
      {second, _} = WebAuthn.begin_registration(user)
      {_a, params} = SoftwareAuthenticator.create(first_options)

      assert {:error, %Wax.InvalidClientDataError{reason: :challenge_mismatch}} =
               WebAuthn.finish_registration(user, second, params, name: "x")

      assert passkey_count() == 0
    end

    test "an authenticator that did not verify the user", %{user: user} do
      {challenge, options} = WebAuthn.begin_registration(user)
      {_a, params} = SoftwareAuthenticator.create(options, user_verified: false)

      assert {:error, %Wax.InvalidClientDataError{reason: :user_not_verified}} =
               WebAuthn.finish_registration(user, challenge, params, name: "x")

      assert passkey_count() == 0
    end

    test "a credential id that is already registered", %{user: user} do
      {challenge, options} = WebAuthn.begin_registration(user)
      {_a, params} = SoftwareAuthenticator.create(options)
      assert {:ok, _} = WebAuthn.finish_registration(user, challenge, params, name: "x")

      partner = insert_user!("Partner")
      {challenge, _options} = WebAuthn.begin_registration(partner)
      params = re_answer(params, challenge)

      assert {:error, %Ecto.Changeset{} = changeset} =
               WebAuthn.finish_registration(partner, challenge, params, name: "y")

      assert {"has already been taken", _} = changeset.errors[:credential_id]
      assert passkey_count() == 1
    end

    test "a missing passkey name", %{user: user} do
      {challenge, options} = WebAuthn.begin_registration(user)
      {_a, params} = SoftwareAuthenticator.create(options)

      assert {:error, %Ecto.Changeset{} = changeset} =
               WebAuthn.finish_registration(user, challenge, params)

      assert changeset.errors[:name]
      assert passkey_count() == 0
    end

    test "an authentication challenge", %{user: user} do
      {_challenge, options} = WebAuthn.begin_registration(user)
      {_a, params} = SoftwareAuthenticator.create(options)
      {wrong, _} = WebAuthn.begin_authentication()

      assert {:error, :wrong_challenge_type} =
               WebAuthn.finish_registration(user, wrong, params, name: "x")
    end

    test "malformed responses without raising", %{user: user} do
      {challenge, options} = WebAuthn.begin_registration(user)
      {_a, params} = SoftwareAuthenticator.create(options)

      cases = [
        {%{}, :malformed_response},
        {%{"response" => "nope"}, :malformed_response},
        {put_in(params, ["response", "attestationObject"], "not base64url!"),
         :malformed_response},
        {put_in(params, ["response", "clientDataJSON"], nil), :malformed_response},
        # Valid CBOR, wrong shape: Wax raises a MatchError on these internally.
        {put_in(params, ["response", "attestationObject"], b64(CBOR.encode(["fmt", "none"]))),
         :malformed_response},
        {put_in(params, ["response", "attestationObject"], b64(CBOR.encode(%{"fmt" => "none"}))),
         :malformed_response},
        {put_in(params, ["response", "attestationObject"], b64(<<0xFF, 1, 2>>)),
         %Wax.InvalidCBORError{}},
        {put_in(params, ["response", "clientDataJSON"], b64("{not json")),
         %Wax.InvalidClientDataError{reason: :malformed_json}}
      ]

      for {bad, expected} <- cases do
        assert {:error, reason} = WebAuthn.finish_registration(user, challenge, bad, name: "x")

        assert same_error?(reason, expected),
               "expected #{inspect(expected)}, got #{inspect(reason)}"
      end

      assert passkey_count() == 0
    end
  end

  describe "finish_authentication/3 rejects" do
    setup %{user: user} do
      {_passkey, authenticator} = register!(user)

      # One successful login first, so the stored counter is non-zero and `last_used_at`
      # is set: every rejection below must leave both untouched.
      {challenge, options} = WebAuthn.begin_authentication()
      {authenticator, params} = SoftwareAuthenticator.get(authenticator, options)

      {:ok, %{passkey: passkey}} =
        WebAuthn.finish_authentication(challenge, params, now: ~U[2026-09-01 12:00:00Z])

      %{passkey: passkey, authenticator: authenticator}
    end

    test "a tampered signature", %{passkey: passkey, authenticator: authenticator} do
      {challenge, options} = WebAuthn.begin_authentication()
      {_a, params} = SoftwareAuthenticator.get(authenticator, options)

      forged = params |> fetch!(["response", "signature"]) |> flip_last_byte()
      params = put_in(params, ["response", "signature"], b64(forged))

      assert {:error, %Wax.InvalidSignatureError{}} =
               WebAuthn.finish_authentication(challenge, params)

      assert_untouched(passkey)
    end

    test "authenticator data altered after signing", %{
      passkey: passkey,
      authenticator: authenticator
    } do
      {challenge, options} = WebAuthn.begin_authentication()
      {_a, params} = SoftwareAuthenticator.get(authenticator, options)

      # Bump the signed counter by hand: the signature no longer covers these bytes.
      <<head::binary-size(33), count::unsigned-big-integer-size(32)>> =
        fetch!(params, ["response", "authenticatorData"])

      params =
        put_in(
          params,
          ["response", "authenticatorData"],
          b64(head <> <<count + 100::unsigned-big-integer-size(32)>>)
        )

      assert {:error, %Wax.InvalidSignatureError{}} =
               WebAuthn.finish_authentication(challenge, params)

      assert_untouched(passkey)
    end

    test "a replayed assertion presented against a fresh challenge", %{
      passkey: passkey,
      authenticator: authenticator
    } do
      {first, options} = WebAuthn.begin_authentication()
      {_a, params} = SoftwareAuthenticator.get(authenticator, options)
      assert {:ok, %{passkey: used}} = WebAuthn.finish_authentication(first, params)

      {second, _} = WebAuthn.begin_authentication()

      assert {:error, %Wax.InvalidClientDataError{reason: :challenge_mismatch}} =
               WebAuthn.finish_authentication(second, params)

      assert_untouched(used)
      assert used.id == passkey.id
    end

    test "a replayed assertion presented again against its own challenge", %{
      authenticator: authenticator
    } do
      # The caller must discard a challenge after one attempt; if it does not, the sign
      # count is what stops a second use of the same assertion.
      {challenge, options} = WebAuthn.begin_authentication()
      {_a, params} = SoftwareAuthenticator.get(authenticator, options)
      assert {:ok, %{passkey: used}} = WebAuthn.finish_authentication(challenge, params)

      assert {:error, :sign_count_not_increased} =
               WebAuthn.finish_authentication(challenge, params)

      assert_untouched(used)
    end

    test "an assertion from the wrong origin", %{passkey: passkey, authenticator: authenticator} do
      {challenge, options} = WebAuthn.begin_authentication()

      {_a, params} =
        SoftwareAuthenticator.get(authenticator, options, origin: "https://evil.example")

      assert {:error, %Wax.InvalidClientDataError{reason: :origin_mismatch}} =
               WebAuthn.finish_authentication(challenge, params)

      assert_untouched(passkey)
    end

    test "an assertion whose origin differs only in port or scheme", %{
      passkey: passkey,
      authenticator: authenticator
    } do
      origin = URI.parse(Application.fetch_env!(:wax_, :origin))
      other_port = %{origin | port: origin.port + 1} |> URI.to_string()
      other_scheme = %{origin | scheme: "https"} |> URI.to_string()

      for wrong <- [other_port, other_scheme] do
        {challenge, options} = WebAuthn.begin_authentication()
        {_a, params} = SoftwareAuthenticator.get(authenticator, options, origin: wrong)

        assert {:error, %Wax.InvalidClientDataError{reason: :origin_mismatch}} =
                 WebAuthn.finish_authentication(challenge, params)
      end

      assert_untouched(passkey)
    end

    test "an assertion for the wrong rp_id", %{passkey: passkey, authenticator: authenticator} do
      {challenge, options} = WebAuthn.begin_authentication()
      {_a, params} = SoftwareAuthenticator.get(authenticator, options, rp_id: "evil.example")

      assert {:error, %Wax.InvalidClientDataError{reason: :rp_id_mismatch}} =
               WebAuthn.finish_authentication(challenge, params)

      assert_untouched(passkey)
    end

    test "an expired challenge", %{passkey: passkey, authenticator: authenticator} do
      {challenge, options} = WebAuthn.begin_authentication()
      {_a, params} = SoftwareAuthenticator.get(authenticator, options)

      assert {:error, %Wax.ExpiredChallengeError{}} =
               WebAuthn.finish_authentication(expire(challenge), params)

      assert_untouched(passkey)
    end

    test "a sign count that did not increase", %{passkey: passkey, authenticator: authenticator} do
      assert passkey.sign_count == 1

      # A cloned authenticator re-reports the counter already seen. The signature is
      # genuine, so Wax accepts it; our own comparison must not.
      {challenge, options} = WebAuthn.begin_authentication()
      {_a, params} = SoftwareAuthenticator.get(authenticator, options, sign_count: 1)

      assert {:error, :sign_count_not_increased} =
               WebAuthn.finish_authentication(challenge, params)

      assert_untouched(passkey)
    end

    test "a sign count that went backwards, including back to 0", %{authenticator: authenticator} do
      {challenge, options} = WebAuthn.begin_authentication()
      {authenticator, params} = SoftwareAuthenticator.get(authenticator, options)
      assert {:ok, %{passkey: passkey}} = WebAuthn.finish_authentication(challenge, params)
      assert passkey.sign_count == 2

      for count <- [1, 0] do
        {challenge, options} = WebAuthn.begin_authentication()
        {_a, params} = SoftwareAuthenticator.get(authenticator, options, sign_count: count)

        assert {:error, :sign_count_not_increased} =
                 WebAuthn.finish_authentication(challenge, params)
      end

      assert_untouched(passkey)
    end

    test "an assertion without a user handle", %{passkey: passkey, authenticator: authenticator} do
      {challenge, options} = WebAuthn.begin_authentication()
      {_a, params} = SoftwareAuthenticator.get(authenticator, options, user_handle: nil)

      assert {:error, :missing_user_handle} = WebAuthn.finish_authentication(challenge, params)
      assert_untouched(passkey)
    end

    test "a user handle that is not one of ours", %{
      passkey: passkey,
      authenticator: authenticator
    } do
      {challenge, options} = WebAuthn.begin_authentication()
      {_a, params} = SoftwareAuthenticator.get(authenticator, options, user_handle: "wannes")

      assert {:error, :invalid_user_handle} = WebAuthn.finish_authentication(challenge, params)
      assert_untouched(passkey)
    end

    test "a user handle for a user that does not exist", %{
      passkey: passkey,
      authenticator: authenticator
    } do
      {challenge, options} = WebAuthn.begin_authentication()
      missing = WebAuthn.user_handle(%User{id: passkey.user_id + 1000})
      {_a, params} = SoftwareAuthenticator.get(authenticator, options, user_handle: missing)

      assert {:error, :unknown_user} = WebAuthn.finish_authentication(challenge, params)
      assert_untouched(passkey)
    end

    test "a genuine credential presented under another user's handle", %{
      passkey: passkey,
      authenticator: authenticator
    } do
      partner = insert_user!("Partner")
      {_partner_passkey, _} = register!(partner)

      {challenge, options} = WebAuthn.begin_authentication()

      {_a, params} =
        SoftwareAuthenticator.get(authenticator, options,
          user_handle: WebAuthn.user_handle(partner)
        )

      assert {:error, %Wax.InvalidClientDataError{reason: :credential_id_mismatch}} =
               WebAuthn.finish_authentication(challenge, params)

      assert_untouched(passkey)
    end

    test "an authenticator that did not verify the user", %{
      passkey: passkey,
      authenticator: authenticator
    } do
      {challenge, options} = WebAuthn.begin_authentication()
      {_a, params} = SoftwareAuthenticator.get(authenticator, options, user_verified: false)

      assert {:error, %Wax.InvalidClientDataError{reason: :user_not_verified}} =
               WebAuthn.finish_authentication(challenge, params)

      assert_untouched(passkey)
    end

    test "a registration challenge", %{passkey: passkey, authenticator: authenticator, user: user} do
      {_challenge, options} = WebAuthn.begin_authentication()
      {_a, params} = SoftwareAuthenticator.get(authenticator, options)
      {wrong, _} = WebAuthn.begin_registration(user)

      assert {:error, :wrong_challenge_type} = WebAuthn.finish_authentication(wrong, params)
      assert_untouched(passkey)
    end

    test "malformed assertions without raising", %{passkey: passkey, authenticator: authenticator} do
      {challenge, options} = WebAuthn.begin_authentication()
      {_a, params} = SoftwareAuthenticator.get(authenticator, options)

      cases = [
        {%{}, :malformed_response},
        {%{"rawId" => params["rawId"], "response" => []}, :malformed_response},
        {put_in(params, ["response", "signature"], 42), :malformed_response},
        {put_in(params, ["response", "authenticatorData"], "***"), :malformed_response},
        {put_in(params, ["response", "authenticatorData"], b64(<<1, 2, 3>>)),
         %Wax.InvalidAuthenticatorDataError{}},
        {put_in(params, ["response", "clientDataJSON"], b64("{not json")),
         %Wax.InvalidClientDataError{reason: :malformed_json}}
      ]

      for {bad, expected} <- cases do
        assert {:error, reason} = WebAuthn.finish_authentication(challenge, bad)

        assert same_error?(reason, expected),
               "expected #{inspect(expected)}, got #{inspect(reason)}"
      end

      assert_untouched(passkey)
    end
  end

  describe "an independent real-world test vector" do
    # From tanguilp/wax's conformance-derived suite (test/wax_test.exs, "Valid
    # authentication"): an assertion produced by an actual authenticator, not by our
    # software one. Its key must survive our storage codec and still verify.
    test "a genuine authenticator assertion verifies with a key that went through our codec" do
      cose_key = %{
        -3 =>
          <<98, 100, 223, 32, 227, 200, 15, 188, 189, 232, 138, 105, 22, 180, 62, 243, 3, 141,
            155, 218, 234, 56, 73, 119, 68, 40, 15, 226, 166, 223, 142, 70>>,
        -2 =>
          <<208, 207, 104, 44, 202, 126, 18, 157, 148, 21, 163, 59, 225, 16, 109, 136, 12, 65,
            158, 142, 164, 239, 142, 27, 193, 171, 144, 237, 209, 71, 65, 213>>,
        -1 => 1,
        1 => 2,
        3 => -7
      }

      decoded = cose_key |> Passkey.encode_cose_key() |> Passkey.decode_cose_key()
      assert decoded == cose_key

      raw_id =
        "DFQrvtpFuI9EXiqRcbN/a26zy20MZfECYuqf4deP6FzpwpWLjZrBAIFrxnNbiwo05uxMoBP+0dnlQMpZLAE9UQ=="

      # The vector was captured at this origin, so it is fixed here by necessity.
      challenge =
        Wax.Challenge.new(
          type: :authentication,
          bytes:
            <<116, 133, 61, 70, 123, 121, 10, 178, 236, 90, 87, 60, 49, 217, 68, 174, 49, 237,
              210, 27, 49, 158, 107, 163, 50, 109, 253, 21, 8, 125, 125, 154>>,
          origin: "http://localhost:4000",
          rp_id: "localhost"
        )

      client_data_json =
        ~s({"challenge":"dIU9Rnt5CrLsWlc8MdlErjHt0hsxnmujMm39FQh9fZo","clientExtensions":{},"hashAlgorithm":"SHA-256","origin":"http://localhost:4000","type":"webauthn.get"})

      auth_data = Base.decode64!("SZYN5YgOjGh0NBcPZHZgW4/krrmihjLHmVzzuoMdl2MBAAAANg==")

      sig =
        Base.decode64!(
          "MEQCIHHZ5/2J9enVkAYKFcmNCAxcFz7Bs/A2f8THzhtCS4PqAiAxZXMONoQrnRQviYWn4wqGwQZr20ukNltjH88SIn9k2Q=="
        )

      assert {:ok, %{sign_count: 54}} =
               Wax.authenticate(raw_id, auth_data, sig, client_data_json, challenge, [
                 {raw_id, decoded}
               ])
    end
  end

  ## Helpers

  defp insert_user!(display_name) do
    %User{} |> User.changeset(%{display_name: display_name}) |> Repo.insert!()
  end

  # Runs a full registration ceremony and returns the persisted passkey plus the
  # authenticator that holds its private key.
  defp register!(user, authenticator_opts \\ []) do
    {challenge, options} = WebAuthn.begin_registration(user)
    {authenticator, params} = SoftwareAuthenticator.create(options, authenticator_opts)

    {:ok, passkey} =
      WebAuthn.finish_registration(user, challenge, params, name: "Passkey #{user.id}")

    {passkey, authenticator}
  end

  # Wax compares `issued_at` (seconds) against `timeout`; backdating is how a test waits.
  defp backdate(challenge, seconds), do: %{challenge | issued_at: challenge.issued_at - seconds}
  defp expire(challenge), do: backdate(challenge, challenge.timeout)

  # Re-targets a captured registration response at a new challenge by rewriting its
  # clientDataJSON; the attestation object ("none" format) carries no signature over it.
  defp re_answer(params, challenge) do
    client_data =
      params
      |> fetch!(["response", "clientDataJSON"])
      |> Jason.decode!()
      |> Map.put("challenge", b64(challenge.bytes))
      |> Jason.encode!()

    put_in(params, ["response", "clientDataJSON"], b64(client_data))
  end

  # A rejected assertion must change neither the counter nor the last-used moment.
  defp assert_untouched(%Passkey{} = before) do
    after_ = Repo.get!(Passkey, before.id)
    assert after_.sign_count == before.sign_count
    assert after_.last_used_at == before.last_used_at
  end

  defp same_error?(%{__struct__: module} = reason, %{__struct__: module} = expected),
    do: Map.get(reason, :reason) == Map.get(expected, :reason)

  defp same_error?(reason, expected), do: reason == expected

  defp passkey_count, do: Repo.aggregate(Passkey, :count)

  defp fetch!(params, path), do: params |> get_in(path) |> Base.url_decode64!(padding: false)

  defp flip_last_byte(bin) do
    size = byte_size(bin) - 1
    <<head::binary-size(^size), last>> = bin
    head <> <<Bitwise.bxor(last, 0xFF)>>
  end

  defp b64(bin), do: Base.url_encode64(bin, padding: false)
end
