defmodule WeddingPlanner.References.Reference do
  @moduledoc """
  A reference attached to an offer or an invoice (`docs/04-cross-cutting.md` `XC-20`): a
  **label** and **either** an uploaded file **or** a URL — `kind` says which.

  The table has no owner column yet (`DR-28`): C2 adds `offer_id` and B2 `invoice_id`,
  each with a `belongs_to` here. Until then the owner is described by
  `WeddingPlanner.References.Owner`, whose `attrs` are put on the struct before any
  changeset runs — never cast.

  ## Changesets

    * `url_changeset/2` — a new URL reference: `label` and `url` are cast. The URL must be
      `http` or `https` with a host (`DR-29`); `javascript:`, `data:`, `file:`, `ftp:`
      and scheme-less input are refused.
    * `file_changeset/2` — a new file reference: **only `label` is cast**. The file fields
      (`file_key`, `file_name`, `content_type`, `byte_size`) come from
      `WeddingPlanner.References.Storage.store/2` and are put on the struct by
      `WeddingPlanner.References` before this runs, so no client input can name a file
      on disk or claim a type. A blank label defaults to the original filename
      (`DR-29`).
    * `label_changeset/2` — editing an existing reference: the label, plus the URL for a
      `url` reference. A file reference's file is never replaced; delete and re-attach.

  Labels are trimmed and 1–200 characters; URLs are trimmed and at most 2000.
  """
  use Ecto.Schema

  import Ecto.Changeset

  @type t :: %__MODULE__{}

  @label_max 200
  @url_max 2000

  schema "references" do
    field :label, :string
    field :kind, Ecto.Enum, values: [:file, :url]
    field :url, :string
    field :file_key, :string
    field :file_name, :string
    field :content_type, :string
    field :byte_size, :integer

    timestamps(type: :utc_datetime)
  end

  @doc "The maximum label length, in characters."
  @spec label_max() :: pos_integer()
  def label_max, do: @label_max

  @doc """
  A new URL reference (`XC-20`, `DR-29`). Casts `label` and `url`; sets `kind` to `:url`.
  """
  @spec url_changeset(t(), map()) :: Ecto.Changeset.t()
  def url_changeset(%__MODULE__{} = reference, attrs) do
    reference
    |> cast(attrs, [:label, :url])
    |> put_change(:kind, :url)
    |> validate_label()
    |> validate_url()
  end

  @doc """
  A new file reference (`XC-20`, `DR-29`). Only `label` is cast; the file fields MUST
  already be on `reference` (set from `Storage.store/2`'s result). A blank label defaults
  to `reference.file_name`. Sets `kind` to `:file`.
  """
  @spec file_changeset(t(), map()) :: Ecto.Changeset.t()
  def file_changeset(%__MODULE__{} = reference, attrs) do
    reference
    |> cast(attrs, [:label])
    |> put_change(:kind, :file)
    |> update_change(:label, &trim/1)
    |> default_label(reference.file_name)
    |> validate_label()
    |> validate_required([:file_key, :file_name, :content_type, :byte_size])
  end

  @doc """
  Edits an existing reference: its label, and for a `url` reference its URL too. A file
  reference's file fields are never castable.
  """
  @spec label_changeset(t(), map()) :: Ecto.Changeset.t()
  def label_changeset(%__MODULE__{kind: :url} = reference, attrs) do
    reference
    |> cast(attrs, [:label, :url])
    |> validate_label()
    |> validate_url()
  end

  def label_changeset(%__MODULE__{kind: :file} = reference, attrs) do
    reference
    |> cast(attrs, [:label])
    |> validate_label()
  end

  defp validate_label(changeset) do
    changeset
    |> update_change(:label, &trim/1)
    |> validate_required([:label])
    |> validate_length(:label, min: 1, max: @label_max)
  end

  defp validate_url(changeset) do
    changeset
    |> update_change(:url, &trim/1)
    |> validate_required([:url])
    |> validate_length(:url, max: @url_max)
    |> validate_change(:url, fn :url, url ->
      if http_url?(url), do: [], else: [url: "must be an http:// or https:// address"]
    end)
  end

  # `DR-29`: http/https only, with a non-empty host. `URI.new/1` refuses malformed input
  # (spaces, invalid characters) and lower-cases the scheme, so "HTTPS://…" passes and
  # "javascript:…", "data:…", "file:///…" and "example.com" (no scheme) do not.
  defp http_url?(url) do
    case URI.new(url) do
      {:ok, %URI{scheme: scheme, host: host}}
      when scheme in ["http", "https"] and is_binary(host) and host != "" ->
        true

      _ ->
        false
    end
  end

  # A blank label on upload defaults to the original filename (`DR-29`). `cast/3` turns
  # "" and whitespace-only input into "no change", so the label is still nil here.
  defp default_label(changeset, file_name) do
    case get_field(changeset, :label) do
      label when label in [nil, ""] -> put_change(changeset, :label, file_name)
      _ -> changeset
    end
  end

  defp trim(value) when is_binary(value), do: String.trim(value)
  defp trim(value), do: value
end
