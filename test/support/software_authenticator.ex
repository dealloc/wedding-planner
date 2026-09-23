defmodule WeddingPlanner.SoftwareAuthenticator do
  @moduledoc """
  A minimal software WebAuthn authenticator for testing `WeddingPlanner.Accounts.WebAuthn`.

  Every structure is built from the WebAuthn L2 spec text rather than from Wax's
  internals, so a passing ceremony proves our options maps, base64url layer and COSE key
  storage agree with the byte layout the spec mandates — not merely that Wax agrees with
  itself. It covers the ES256 / `fmt: "none"` path only.

      authData = rpIdHash(32) || flags(1) || signCount(4) || [attestedCredentialData]
      flags    = BS<<4 | BE<<3 | UV<<2 | UP<<0, plus AT<<6 on registration
      attestedCredentialData = aaguid(16) || credIdLen(2) || credId || COSE key (CBOR)
      attestationObject = CBOR{fmt, attStmt, authData}
      assertion signature = ECDSA-SHA256(authData || SHA256(clientDataJSON)), DER-encoded

  Knobs exist for every way a hostile or broken client could differ from an honest one:
  `:origin`, `:rp_id`, `:sign_count`, `:user_handle`, `:user_verified`. The default origin
  is whatever `config :wax_, :origin` holds, so tests follow runtime config rather than
  hard-coding a port.
  """

  import Bitwise, only: [|||: 2]

  @aaguid <<0xB9, 0x3F, 0xD9, 0x61, 0xF2, 0xE6, 0x46, 0x2F, 0xB1, 0x22, 0x82, 0x00, 0x22, 0x2A,
            0x14, 0x51>>

  # Flag bits (WebAuthn L2 §6.1).
  @up 0x01
  @uv 0x04
  @be 0x08
  @bs 0x10
  @at 0x40

  defstruct [
    :credential_id,
    :private_key,
    :cose_key,
    :user_handle,
    :aaguid,
    :counter,
    sign_count: 0
  ]

  @type t :: %__MODULE__{}

  @doc """
  Performs `navigator.credentials.create()` against a creation options map as built by
  `WebAuthn.begin_registration/1`. Returns the authenticator (holding the private key)
  and the JSON-shaped credential a browser would send back.

  Options: `:origin`, `:rp_id`, `:user_verified` (default `true`), and `:counter` —
  `:incrementing` (default) or `:zero` for an authenticator that always reports 0, as most
  synced platform passkeys do.
  """
  @spec create(map(), keyword()) :: {t(), map()}
  def create(options, opts \\ []) do
    origin = Keyword.get_lazy(opts, :origin, &configured_origin/0)
    rp_id = Keyword.get(opts, :rp_id, options.rp.id)
    user_verified = Keyword.get(opts, :user_verified, true)
    credential_id = :crypto.strong_rand_bytes(32)

    {pub, priv} = :crypto.generate_key(:ecdh, :prime256v1)
    <<4, x::binary-size(32), y::binary-size(32)>> = pub

    # kty: EC2, alg: ES256, crv: P-256, x, y
    cose_key = %{1 => 2, 3 => -7, -1 => 1, -2 => x, -3 => y}

    client_data_json = client_data("webauthn.create", options.challenge, origin)

    attested_credential_data =
      @aaguid <>
        <<byte_size(credential_id)::unsigned-big-integer-size(16)>> <>
        credential_id <>
        cbor_cose_key(cose_key)

    auth_data =
      auth_data(rp_id, flags(user_verified) ||| @at, 0) <> attested_credential_data

    attestation_object =
      CBOR.encode(%{
        "fmt" => "none",
        "attStmt" => %{},
        "authData" => %CBOR.Tag{tag: :bytes, value: auth_data}
      })

    authenticator = %__MODULE__{
      credential_id: credential_id,
      private_key: priv,
      cose_key: cose_key,
      user_handle: Base.url_decode64!(options.user.id, padding: false),
      aaguid: @aaguid,
      counter: Keyword.get(opts, :counter, :incrementing),
      sign_count: 0
    }

    params = %{
      "id" => b64(credential_id),
      "rawId" => b64(credential_id),
      "type" => "public-key",
      "response" => %{
        "attestationObject" => b64(attestation_object),
        "clientDataJSON" => b64(client_data_json),
        "transports" => ["internal", "hybrid"]
      }
    }

    {authenticator, params}
  end

  @doc """
  Performs `navigator.credentials.get()` against a request options map as built by
  `WebAuthn.begin_authentication/0`. Returns the authenticator with its counter advanced
  and the JSON-shaped assertion.

  Options: `:origin`, `:rp_id`, `:user_verified`, `:sign_count` (report this counter
  instead of the next one — how a cloned authenticator is forged) and `:user_handle`
  (raw bytes, or `nil` to omit it).
  """
  @spec get(t(), map(), keyword()) :: {t(), map()}
  def get(%__MODULE__{} = auth, options, opts \\ []) do
    origin = Keyword.get_lazy(opts, :origin, &configured_origin/0)
    rp_id = Keyword.get(opts, :rp_id, options.rpId)
    user_verified = Keyword.get(opts, :user_verified, true)
    user_handle = Keyword.get(opts, :user_handle, auth.user_handle)

    sign_count =
      Keyword.get_lazy(opts, :sign_count, fn ->
        if auth.counter == :zero, do: 0, else: auth.sign_count + 1
      end)

    client_data_json = client_data("webauthn.get", options.challenge, origin)
    auth_data = auth_data(rp_id, flags(user_verified), sign_count)

    signature =
      :crypto.sign(
        :ecdsa,
        :sha256,
        auth_data <> :crypto.hash(:sha256, client_data_json),
        [auth.private_key, :prime256v1]
      )

    params = %{
      "id" => b64(auth.credential_id),
      "rawId" => b64(auth.credential_id),
      "type" => "public-key",
      "response" => %{
        "authenticatorData" => b64(auth_data),
        "clientDataJSON" => b64(client_data_json),
        "signature" => b64(signature),
        "userHandle" => user_handle && b64(user_handle)
      }
    }

    {%{auth | sign_count: sign_count}, params}
  end

  defp client_data(type, challenge, origin) do
    Jason.encode!(%{type: type, challenge: challenge, origin: origin, crossOrigin: false})
  end

  defp auth_data(rp_id, flags, sign_count) do
    :crypto.hash(:sha256, rp_id) <> <<flags>> <> <<sign_count::unsigned-big-integer-size(32)>>
  end

  defp flags(true), do: @up ||| @uv ||| @be ||| @bs
  defp flags(false), do: @up ||| @be ||| @bs

  defp cbor_cose_key(cose_key) do
    cose_key
    |> Map.new(fn
      {k, v} when is_binary(v) -> {k, %CBOR.Tag{tag: :bytes, value: v}}
      {k, v} -> {k, v}
    end)
    |> CBOR.encode()
  end

  defp configured_origin, do: Application.fetch_env!(:wax_, :origin)

  defp b64(bin), do: Base.url_encode64(bin, padding: false)
end
