defmodule WeddingPlannerWeb.ReferenceFileController do
  @moduledoc """
  Serves an uploaded reference file to a signed-in user (`docs/04-cross-cutting.md`
  `XC-22`; `DR-30`): `show/2` inline (an image renders, a PDF opens in the browser's
  viewer), `download/2` as an attachment under its original filename.

  Both routes sit behind the `:require_authenticated_user` pipeline (`AUTH-01`) and
  outside the `live_session` — they are plain HTTP responses an `<img>`, `<iframe>` or
  link can point at.

  ## Responses

    * The file is read from the local volume via `WeddingPlanner.References.Storage.path_for/1`
      and sent with `Plug.Conn.send_file/3` — never from the backup bucket (`XC-23`,
      `D-32`).
    * `content-type` is the stored `content_type`, which `Storage` sniffed from the bytes
      at upload (`DR-29`) — never derived from the filename. With
      `x-content-type-options: nosniff` that is the guard against serving something a
      browser would execute: only PDF, PNG, JPEG and WebP ever reach this point, so no CSP
      sandbox is added (it breaks Chrome's PDF viewer).
    * `cache-control: private, max-age=3600` — a stored file never changes (a reference's
      file is never replaced), but it must not sit in a shared cache.
    * `content-disposition` per RFC 6266 with an RFC 5987 `filename*`
      (`content_disposition/2`).

  ## 404s

  An unknown (or non-integer) id, a `url`-kind reference (it has no file), and a row
  whose file is **missing from disk** are all 404 — never a 500. The last is expected
  after a disaster restore: the database (Litestream) can be newer than the uploads
  directory (`rclone`, every 15 minutes), see `DEPLOY.md` "The backup asymmetry". It gets
  a short explanatory body and a `Logger.warning`.
  """
  use WeddingPlannerWeb, :controller

  require Logger

  alias WeddingPlanner.References
  alias WeddingPlanner.References.Reference
  alias WeddingPlanner.References.Storage

  @missing_body "This file is missing from storage. If the app was recently restored from backup, it may not have been synced yet."

  @doc "Inline: `GET /references/:id/file`."
  def show(conn, %{"id" => id}), do: serve(conn, id, :inline)

  @doc "Attachment: `GET /references/:id/download`."
  def download(conn, %{"id" => id}), do: serve(conn, id, :attachment)

  defp serve(conn, id, disposition) do
    case References.get_reference(id) do
      %Reference{kind: :file} = reference ->
        if Storage.exists?(reference) do
          send_reference(conn, reference, disposition)
        else
          Logger.warning(
            "reference #{reference.id} file missing from storage: #{Storage.path_for(reference)}"
          )

          not_found(conn, @missing_body)
        end

      _nil_or_url_reference ->
        not_found(conn, "Not found.")
    end
  end

  defp send_reference(conn, reference, disposition) do
    conn
    |> put_resp_header("content-type", reference.content_type)
    |> put_resp_header("x-content-type-options", "nosniff")
    |> put_resp_header("cache-control", "private, max-age=3600")
    |> put_resp_header(
      "content-disposition",
      content_disposition(disposition, reference.file_name)
    )
    |> send_file(200, Storage.path_for(reference))
  end

  defp not_found(conn, body) do
    conn
    |> put_resp_content_type("text/plain")
    |> send_resp(404, body)
  end

  @doc """
  The `content-disposition` value for `type` (`:inline` or `:attachment`) and the
  original filename (RFC 6266, RFC 5987):

      inline; filename="Offerte_Chateau.pdf"; filename*=UTF-8''Offerte_Ch%C3%A2teau.pdf

  The quoted `filename` is an ASCII fallback for clients that ignore `filename*`: accents
  are dropped (NFD, combining marks removed), then anything left that is not printable
  ASCII, plus `"` and `\\`, becomes `_`. `filename*` carries the exact name, UTF-8 and
  percent-encoded except for RFC 5987 `attr-char`s.
  """
  @spec content_disposition(:inline | :attachment, String.t()) :: String.t()
  def content_disposition(type, file_name) when type in [:inline, :attachment] do
    ~s(#{type}; filename="#{ascii_fallback(file_name)}"; filename*=UTF-8''#{rfc5987_encode(file_name)})
  end

  defp ascii_fallback(name) do
    name
    |> :unicode.characters_to_nfd_binary()
    |> String.replace(~r/\p{Mn}/u, "")
    |> String.replace(~r/[^\x20-\x7E]|["\\]/u, "_")
  end

  defp rfc5987_encode(name), do: URI.encode(name, &attr_char?/1)

  # RFC 5987 attr-char: ALPHA / DIGIT / "!" / "#" / "$" / "&" / "+" / "-" / "." / "^" /
  # "_" / "`" / "|" / "~"
  defp attr_char?(c) when c in ?a..?z or c in ?A..?Z or c in ?0..?9, do: true
  defp attr_char?(c), do: c in ~c"!#$&+-.^_`|~"
end
