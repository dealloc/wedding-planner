defmodule WeddingPlanner.Accounts.WebAuthn do
  @moduledoc """
  The WebAuthn registration and authentication ceremonies (AUTH-02, D-12).

  `wax_` verifies the cryptography. It does not build the options maps the browser
  needs, it does not do base64url, it does not compare sign counts and it does not know
  about our tables. Those are this module's job:

    * **Registration** — `begin_registration/1` issues a challenge plus the
      `PublicKeyCredentialCreationOptions` for `navigator.credentials.create()`, requiring
      a discoverable credential (resident key) and user verification.
      `finish_registration/4` verifies the authenticator's response, CBOR-encodes the COSE
      key and persists a `Passkey` row.
    * **Authentication** — `begin_authentication/0` issues a challenge plus the
      `PublicKeyCredentialRequestOptions` for `navigator.credentials.get()` with **no**
      `allowCredentials`: the login is usernameless. `finish_authentication/3` resolves
      the user from the returned `userHandle`, verifies the assertion against that user's
      stored keys, rejects a sign count that did not increase, and records the new count
      and last-used moment (AUTH-08, NFR-21).

  ## Configuration

  `origin` and `rp_id` are never set here. `Wax.Challenge.new/1` reads them from
  `config :wax_` (see `config/runtime.exs`) at the moment a challenge is issued, so the
  web process and any release command agree on the relying party automatically. The
  origin must match the scheme, host and port the browser sees exactly; `rp_id` is
  effectively permanent once a real passkey is registered against it.

  The **challenge timeout** is set explicitly by this module (`challenge_timeout_seconds/0`)
  rather than inherited from Wax, whose default is 120 seconds despite its README
  claiming 20 minutes. It bounds one ceremony — the time between the challenge being
  issued and the authenticator's answer arriving — and is unrelated to AUTH-06's
  15-minute enrollment link expiry, which lives on `EnrollmentLink`.

  ## Holding the challenge

  The caller keeps the `%Wax.Challenge{}` returned by a `begin_*` function (in a LiveView
  assign, not a cookie) and passes it to the matching `finish_*` function. A challenge
  MUST be discarded after one `finish_*` attempt, successful or not. For an authenticator
  whose counter increments, a replayed assertion is also rejected by the sign count; for
  one that always reports 0 (most synced platform passkeys), single use of the challenge
  is the only replay defence.

  ## Errors

  Every `finish_*` function returns `{:error, reason}` rather than raising on hostile or
  malformed input. `reason` is one of:

    * a Wax exception struct — e.g. `%Wax.InvalidSignatureError{}`,
      `%Wax.ExpiredChallengeError{}`, or `%Wax.InvalidClientDataError{reason: r}` with `r`
      in `:challenge_mismatch`, `:origin_mismatch`, `:rp_id_mismatch`,
      `:credential_id_mismatch`, `:user_not_verified`, …
    * `:wrong_challenge_type` — a registration challenge passed to authentication or the
      reverse
    * `:malformed_response` — a missing field, bad base64url, or bytes Wax cannot parse
    * `:missing_user_handle`, `:invalid_user_handle`, `:unknown_user` — authentication only
    * `:sign_count_not_increased` — authentication only; a possibly cloned authenticator
    * an `%Ecto.Changeset{}` — registration only; the passkey row could not be inserted
      (for instance a credential id that is already registered)

  This module is plain Elixir: no `Plug.Conn`, no socket, so it is directly testable and
  callable from a release command.
  """

  import Ecto.Query, only: [from: 2]

  alias WeddingPlanner.Accounts.Passkey
  alias WeddingPlanner.Accounts.User
  alias WeddingPlanner.Repo

  # One ceremony: challenge issued -> authenticator answers. WebAuthn L3 §5.4.1 suggests
  # 300 000 ms to 600 000 ms when user verification is required; 5 minutes leaves room for
  # a biometric prompt or finding a phone without keeping a challenge alive for long.
  @challenge_timeout_seconds 5 * 60

  @rp_name "Wedding Planner"

  # COSE algorithm identifiers: ES256 and RS256. RS256 is what Windows Hello issues.
  @pub_key_algs [-7, -257]

  @known_transports ~w(usb nfc ble hybrid internal smart-card)

  @type options :: %{required(atom()) => term()}
  @type params :: %{optional(String.t()) => term()}
  @type error ::
          Exception.t()
          | Ecto.Changeset.t()
          | :wrong_challenge_type
          | :malformed_response
          | :missing_user_handle
          | :invalid_user_handle
          | :unknown_user
          | :sign_count_not_increased

  @doc """
  How long, in seconds, a challenge stays valid. Set explicitly: Wax's own default is 120
  seconds. Unrelated to AUTH-06's enrollment link expiry.
  """
  @spec challenge_timeout_seconds() :: pos_integer()
  def challenge_timeout_seconds, do: @challenge_timeout_seconds

  ## Registration

  @doc """
  Starts a registration ceremony for an existing, persisted `user`.

  Returns the challenge to hold until `finish_registration/4`, plus the options map to
  hand to `navigator.credentials.create()` (binary fields base64url-encoded, unpadded).

  The options require a discoverable credential (`residentKey: "required"`) so login
  needs no username, and user verification (`userVerification: "required"`), which Wax
  then enforces on the response. `excludeCredentials` lists the user's existing
  passkeys so the same authenticator cannot be enrolled twice.

  `user.id` is embedded in the credential as its user handle (`user_handle/1`), which is
  how `finish_authentication/3` finds the user again. It is an opaque row id, not PII.
  """
  @spec begin_registration(User.t()) :: {Wax.Challenge.t(), options()}
  def begin_registration(%User{id: user_id} = user) when is_integer(user_id) do
    challenge =
      Wax.new_registration_challenge(
        attestation: "none",
        user_verification: "required",
        timeout: @challenge_timeout_seconds
      )

    options = %{
      challenge: b64(challenge.bytes),
      rp: %{id: challenge.rp_id, name: @rp_name},
      user: %{
        id: b64(user_handle(user)),
        name: user.display_name,
        displayName: user.display_name
      },
      pubKeyCredParams: Enum.map(@pub_key_algs, &%{type: "public-key", alg: &1}),
      authenticatorSelection: %{
        residentKey: "required",
        requireResidentKey: true,
        userVerification: "required"
      },
      attestation: "none",
      timeout: @challenge_timeout_seconds * 1000,
      excludeCredentials: Enum.map(credential_ids(user_id), &%{type: "public-key", id: b64(&1)})
    }

    {challenge, options}
  end

  @doc """
  Verifies the browser's `navigator.credentials.create()` result and persists the new
  passkey for `user`.

  `params` is the credential as the client serialises it, with base64url strings:

      %{
        "rawId" => "...",
        "response" => %{
          "attestationObject" => "...",
          "clientDataJSON" => "...",
          "transports" => ["internal", "hybrid"]
        }
      }

  Options:

    * `:name` — the user-editable passkey name (AUTH-08). Required by the passkey
      changeset; a missing or blank name comes back as `{:error, changeset}`.
    * `:now` — the registration moment, defaulting to the current UTC second.
  """
  @spec finish_registration(User.t(), Wax.Challenge.t(), params(), keyword()) ::
          {:ok, Passkey.t()} | {:error, error()}
  def finish_registration(user, challenge, params, opts \\ [])

  def finish_registration(
        %User{id: user_id},
        %Wax.Challenge{type: :attestation} = challenge,
        params,
        opts
      )
      when is_integer(user_id) do
    with {:ok, attestation_object} <- fetch_b64(params, ["response", "attestationObject"]),
         {:ok, client_data_json} <- fetch_b64(params, ["response", "clientDataJSON"]),
         {:ok, {auth_data, _attestation}} <-
           wax(fn -> Wax.register(attestation_object, client_data_json, challenge) end),
         %Wax.AttestedCredentialData{} = credential <-
           auth_data.attested_credential_data || {:error, :malformed_response} do
      %Passkey{user_id: user_id, sign_count: auth_data.sign_count}
      |> Passkey.registration_changeset(%{
        credential_id: credential.credential_id,
        public_key: Passkey.encode_cose_key(credential.credential_public_key),
        aaguid: credential.aaguid,
        transports: transports(params),
        name: Keyword.get(opts, :name),
        registered_at: Keyword.get_lazy(opts, :now, &now/0)
      })
      |> Repo.insert()

      # AUTH-11: passkey registration must be recorded in the activity log once that
      # service exists (task 19); this is the point where the passkey row now exists.
    end
  end

  def finish_registration(%User{}, %Wax.Challenge{}, _params, _opts),
    do: {:error, :wrong_challenge_type}

  ## Authentication

  @doc """
  Starts a usernameless authentication ceremony.

  Returns the challenge to hold until `finish_authentication/3`, plus the options map to
  hand to `navigator.credentials.get()`. There is deliberately **no**
  `allowCredentials`: the authenticator offers its discoverable credentials for this
  relying party and returns the `userHandle` of the one chosen.
  """
  @spec begin_authentication() :: {Wax.Challenge.t(), options()}
  def begin_authentication do
    challenge =
      Wax.new_authentication_challenge(
        user_verification: "required",
        timeout: @challenge_timeout_seconds
      )

    options = %{
      challenge: b64(challenge.bytes),
      rpId: challenge.rp_id,
      userVerification: "required",
      timeout: @challenge_timeout_seconds * 1000
    }

    {challenge, options}
  end

  @doc """
  Verifies the browser's `navigator.credentials.get()` result.

  The user is resolved from `userHandle`, and only **that user's** passkeys are offered
  to Wax, so a credential presented under another user's handle is rejected
  (`:credential_id_mismatch`). A sign count that failed to increase is rejected as a
  possibly cloned authenticator; an authenticator that always reports 0 is accepted.
  On success the passkey's sign count and `last_used_at` are updated.

  `params`:

      %{
        "rawId" => "...",
        "response" => %{
          "authenticatorData" => "...",
          "clientDataJSON" => "...",
          "signature" => "...",
          "userHandle" => "..."
        }
      }

  Options:

    * `:now` — the last-used moment, defaulting to the current UTC second.
  """
  @spec finish_authentication(Wax.Challenge.t(), params(), keyword()) ::
          {:ok, %{user: User.t(), passkey: Passkey.t()}} | {:error, error()}
  def finish_authentication(challenge, params, opts \\ [])

  def finish_authentication(%Wax.Challenge{type: :authentication} = challenge, params, opts) do
    with {:ok, raw_id} <- fetch_b64(params, ["rawId"]),
         {:ok, auth_data_bin} <- fetch_b64(params, ["response", "authenticatorData"]),
         {:ok, signature} <- fetch_b64(params, ["response", "signature"]),
         {:ok, client_data_json} <- fetch_b64(params, ["response", "clientDataJSON"]),
         {:ok, user, passkeys} <- resolve_user(params),
         credentials = Enum.map(passkeys, &{&1.credential_id, Passkey.cose_key(&1)}),
         {:ok, auth_data} <-
           wax(fn ->
             Wax.authenticate(
               raw_id,
               auth_data_bin,
               signature,
               client_data_json,
               challenge,
               credentials
             )
           end),
         passkey = Enum.find(passkeys, &(&1.credential_id == raw_id)),
         :ok <- check_sign_count(passkey.sign_count, auth_data.sign_count),
         {:ok, passkey} <-
           passkey
           |> Passkey.usage_changeset(auth_data.sign_count, Keyword.get_lazy(opts, :now, &now/0))
           |> Repo.update() do
      {:ok, %{user: user, passkey: passkey}}
    end
  end

  def finish_authentication(%Wax.Challenge{}, _params, _opts),
    do: {:error, :wrong_challenge_type}

  ## User handle

  @doc """
  The WebAuthn user handle for `user`: its row id as 8 big-endian bytes. Opaque, stable
  for the user's lifetime, and free of PII, as WebAuthn requires.
  """
  @spec user_handle(User.t()) :: binary()
  def user_handle(%User{id: id}) when is_integer(id) and id > 0,
    do: <<id::unsigned-big-integer-size(64)>>

  defp resolve_user(params) do
    with {:ok, handle} <- fetch_user_handle(params),
         {:ok, user_id} <- decode_user_handle(handle),
         %User{} = user <- Repo.get(User, user_id) || {:error, :unknown_user} do
      {:ok, user, Repo.all(from p in Passkey, where: p.user_id == ^user.id)}
    end
  end

  # A discoverable-credential assertion MUST carry the user handle; without it we cannot
  # tell whose keys to verify against. `null` is what a browser sends when it is absent.
  defp fetch_user_handle(params) do
    case dig(params, ["response", "userHandle"]) do
      handle when handle in [nil, ""] -> {:error, :missing_user_handle}
      handle -> decode_b64(handle)
    end
  end

  defp decode_user_handle(<<id::unsigned-big-integer-size(64)>>) when id > 0, do: {:ok, id}
  defp decode_user_handle(_), do: {:error, :invalid_user_handle}

  ## Sign count

  # WebAuthn L2 §7.2 step 21. Wax reports the count but does not compare it. If either
  # the stored or the new count is non-zero, the new one must be strictly greater;
  # anything else suggests a cloned authenticator. An authenticator that always reports
  # 0 (most synced platform passkeys) never trips this.
  defp check_sign_count(0, 0), do: :ok
  defp check_sign_count(stored, new) when new > stored, do: :ok
  defp check_sign_count(_stored, _new), do: {:error, :sign_count_not_increased}

  ## Helpers

  # Wax returns `{:error, exception}` for every verification failure, but a few
  # structurally malformed inputs (e.g. an attestation object that is valid CBOR but not
  # the expected map) raise inside it instead. Input here is attacker-controlled, so a
  # raise is turned into an error rather than crashing the caller.
  defp wax(fun) do
    fun.()
  rescue
    _ in [MatchError, CaseClauseError, FunctionClauseError, ArgumentError, KeyError] ->
      {:error, :malformed_response}
  end

  defp credential_ids(user_id) do
    Repo.all(from p in Passkey, where: p.user_id == ^user_id, select: p.credential_id)
  end

  defp transports(params) do
    case dig(params, ["response", "transports"]) do
      list when is_list(list) -> Enum.filter(list, &(&1 in @known_transports))
      _ -> []
    end
  end

  defp fetch_b64(params, path) do
    case dig(params, path) do
      value when is_binary(value) -> decode_b64(value)
      _ -> {:error, :malformed_response}
    end
  end

  defp dig(value, []), do: value
  defp dig(%{} = map, [key | rest]), do: map |> Map.get(key) |> dig(rest)
  defp dig(_, _), do: nil

  # base64url is the encoding every WebAuthn ArrayBuffer travels in. Padding is optional
  # on the way in and never emitted on the way out.
  defp decode_b64(value) when is_binary(value) do
    case Base.url_decode64(value, padding: false) do
      {:ok, bin} -> {:ok, bin}
      :error -> {:error, :malformed_response}
    end
  end

  defp decode_b64(_), do: {:error, :malformed_response}

  defp b64(bin), do: Base.url_encode64(bin, padding: false)

  defp now, do: DateTime.utc_now() |> DateTime.truncate(:second)
end
