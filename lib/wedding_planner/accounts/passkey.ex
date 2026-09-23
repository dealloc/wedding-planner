defmodule WeddingPlanner.Accounts.Passkey do
  @moduledoc """
  A stored WebAuthn credential (AUTH-02, AUTH-08).

  Field choices carried over from the DR-4 spike (`.claude/dr4-webauthn/findings.md`),
  verified end to end against a real WebAuthn ceremony and SQLite (NFR-02):

  * `credential_id` and `public_key` are `:binary` (SQLite BLOB). WebAuthn credential ids
    and COSE keys are raw bytes; storing them base64url-encoded would mean encoding on
    every comparison, and Wax hands us and expects raw binaries.
  * `public_key` holds the **CBOR-encoded COSE key map**. Wax returns the COSE key as an
    Elixir map with negative integer keys (`%{-1 => 1, -2 => <<...>>, 1 => 2, 3 => -7}`),
    which neither JSON nor Ecto's `:map` can round-trip (JSON object keys are strings).
    CBOR is the format the key arrives in anyway, so we re-encode on write and decode on
    read.
  * `transports` is `{:array, :string}`. ecto_sqlite3 stores arrays as JSON text.
  * `sign_count` backs clone detection (findings.md section 4); Wax returns it but does
    not compare it for us.
  * `registered_at` / `last_used_at` are `:utc_datetime` (NFR-21).

  `user_id` and `sign_count` are set programmatically (the former identifies whose
  credential this is, the latter comes from the authenticator, never from a form) and are
  deliberately absent from every `cast/3` call below.
  """
  use Ecto.Schema

  import Ecto.Changeset

  alias WeddingPlanner.Accounts.User

  @type t :: %__MODULE__{}

  schema "passkeys" do
    field :credential_id, :binary
    field :public_key, :binary
    field :aaguid, :binary
    field :transports, {:array, :string}, default: []
    field :sign_count, :integer, default: 0
    field :name, :string
    field :registered_at, :utc_datetime
    field :last_used_at, :utc_datetime

    belongs_to :user, User

    timestamps(type: :utc_datetime)
  end

  @doc """
  Changeset for a newly registered passkey.

  `user_id` and `sign_count` are set programmatically by the caller (e.g.
  `%__MODULE__{user_id: user.id, sign_count: 0}`) and are deliberately absent from
  `cast/3`.
  """
  def registration_changeset(passkey, attrs) do
    passkey
    |> cast(attrs, [
      :credential_id,
      :public_key,
      :aaguid,
      :transports,
      :name,
      :registered_at
    ])
    |> validate_required([:credential_id, :public_key, :name, :registered_at])
    |> validate_length(:name, min: 1, max: 100)
    |> unique_constraint(:credential_id)
  end

  @doc "AUTH-08: the name is user-editable after registration."
  def rename_changeset(passkey, attrs) do
    passkey
    |> cast(attrs, [:name])
    |> validate_required([:name])
    |> validate_length(:name, min: 1, max: 100)
  end

  @doc """
  Records a successful authentication: the new sign count (from the authenticator) and
  the last-used moment. Both are set programmatically, never cast from user input.
  """
  def usage_changeset(passkey, sign_count, now) do
    change(passkey, sign_count: sign_count, last_used_at: now)
  end

  @doc """
  Decodes the stored `public_key` blob back into the COSE key map Wax expects.
  """
  def cose_key(%__MODULE__{public_key: blob}), do: decode_cose_key(blob)

  @doc "Encodes a Wax COSE key map into the blob we store."
  def encode_cose_key(cose_key) when is_map(cose_key) do
    cose_key
    |> Map.new(fn {k, v} -> {k, cbor_value(v)} end)
    |> CBOR.encode()
  end

  @doc "Decodes a stored COSE key blob into the map shape Wax's verifier consumes."
  def decode_cose_key(blob) when is_binary(blob) do
    {:ok, decoded, <<>>} = CBOR.decode(blob)

    Map.new(decoded, fn
      {k, %CBOR.Tag{tag: :bytes, value: v}} -> {k, v}
      {k, v} -> {k, v}
    end)
  end

  # CBOR.encode/1 needs binaries tagged, otherwise it emits them as UTF-8 text strings
  # and the bytes do not survive the round trip.
  defp cbor_value(v) when is_binary(v), do: %CBOR.Tag{tag: :bytes, value: v}
  defp cbor_value(v), do: v
end
