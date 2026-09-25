defmodule WeddingPlannerWeb.TransferController do
  @moduledoc """
  Two authenticated (`AUTH-01`) plain downloads for data transfer (`DR-93`, `DR-97`),
  sitting beside `WeddingPlannerWeb.ExportController` (`DR-87` precedent) in the
  `:require_authenticated_user` scope, outside the `live_session`.

  ## `GET /transfer/export?tz=`

  The whole app, as one JSON file (`WeddingPlanner.Transfer.export/1`). `tz` is the
  viewer's browser zone (`WeddingPlannerWeb.Format.resolve_time_zone/1`, total, falls
  back to the stored default, `NFR-22`), used only for the filename's stamp
  (`WeddingPlanner.Transfer.export_filename/2`, `dd-mm-yyyy-hhmm`, `NFR-23`) — the file's
  own contents are always UTC (`NFR-20`/`NFR-21`). `200`, `application/json`,
  `cache-control: no-store` (the data is live, never cached — the same rule
  `ExportController` follows), and an RFC 6266 attachment disposition built with
  `WeddingPlannerWeb.ReferenceFileController.content_disposition/2`. No activity entry is
  written — an export is a read (`XC-10`, the `DR-87` precedent).

  ## `GET /transfer/safety-copies/:name`

  A safety copy written just before an import (`DR-97`). `name` only ever resolves
  through `WeddingPlanner.Transfer.safety_copy_path/1`, which regex-checks the name
  (`wedding-planner-before-import-dd-mm-yyyy-hhmm[-n].json`) **and** requires an existing
  regular file — so a traversal attempt, an unknown (if valid-looking) name, or a name
  with any suffix outside that pattern all reach the same `404`, never a `500`. The raw
  `name` param is never joined onto a path directly.
  """

  use WeddingPlannerWeb, :controller

  alias WeddingPlanner.Transfer
  alias WeddingPlannerWeb.Format
  alias WeddingPlannerWeb.ReferenceFileController

  @doc "`GET /transfer/export`, `?tz=` the viewer's IANA time zone."
  def export(conn, params) do
    time_zone = Format.resolve_time_zone(params["tz"])
    filename = Transfer.export_filename(DateTime.utc_now(:second), time_zone)
    body = Transfer.export(source_host: source_host())

    conn
    |> put_resp_content_type("application/json")
    |> put_resp_header(
      "content-disposition",
      ReferenceFileController.content_disposition(:attachment, filename)
    )
    |> put_resp_header("cache-control", "no-store")
    |> send_resp(200, body)
  end

  @doc "`GET /transfer/safety-copies/:name`."
  def safety_copy(conn, %{"name" => name}) do
    case Transfer.safety_copy_path(name) do
      {:ok, path} ->
        conn
        |> put_resp_content_type("application/json")
        |> put_resp_header(
          "content-disposition",
          ReferenceFileController.content_disposition(:attachment, name)
        )
        |> put_resp_header("cache-control", "no-store")
        |> send_file(200, path)

      :error ->
        conn
        |> put_resp_content_type("text/plain")
        |> send_resp(404, "Not found.")
    end
  end

  @doc """
  This installation's host, stamped on the export and passed to
  `WeddingPlanner.Transfer.import/3`'s `source_host:` (`DR-93` (1)):
  `WeddingPlannerWeb.Endpoint.url()`'s host plus its port, unless that port is the
  scheme's own default (`"localhost:4000"`, `"wedding.example"`) — the same shape
  `config/runtime.exs` already builds for the WebAuthn origin (a default port for the
  scheme, 443 for https or 80 for http, is omitted, matching how a browser reports
  `window.location.origin`), so the two can't drift apart. `WeddingPlannerWeb.Live.SettingsLive`
  calls this too, for the import it starts.
  """
  @spec source_host() :: String.t()
  def source_host do
    %URI{host: host, port: port, scheme: scheme} = URI.parse(WeddingPlannerWeb.Endpoint.url())

    if port == URI.default_port(scheme) do
      host
    else
      "#{host}:#{port}"
    end
  end
end
