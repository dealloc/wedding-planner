defmodule WeddingPlannerWeb.ExportController do
  @moduledoc """
  `GET /exports/:kind` (`XC-30`, `DR-87`): downloads one module's data as CSV for a
  signed-in user (`AUTH-01`) — a plain controller download (the `DR-30` precedent), not a
  LiveView `push_event`, sitting beside `/references/…` in the `:require_authenticated_user`
  scope and outside the `live_session`.

  `:kind` is looked up in `WeddingPlannerWeb.Export.exporters/0` — a **string**, never
  built into an atom. An unknown kind is a `404` with a short plain-text body, never a
  `500`.

  `today` (for overdue/effective values, `XC-32`) comes from the request's `tz` param —
  the viewer's browser zone (`WeddingPlannerWeb.Format.resolve_time_zone/1`, total, falls
  back to the stored default zone, `NFR-22`) — then
  `WeddingPlanner.Tasks.TodoList.today/1`, **never** `Date.utc_today/0`.

  The response is `200`, `text/csv; charset=utf-8`, `cache-control: no-store` (the data
  is live, `XC-32` — never cached), and an RFC 6266 `content-disposition: attachment`
  whose filename is `<stem>-<dd-mm-yyyy>.csv` (dashes because `today` in the browser's
  zone cannot contain a `/`) — built with the same public helper
  `WeddingPlannerWeb.ReferenceFileController.content_disposition/2` already uses (not
  duplicated, not edited). No activity entry is written and nothing is broadcast — an
  export is a read (`XC-10`).
  """

  use WeddingPlannerWeb, :controller

  alias WeddingPlanner.Tasks.TodoList
  alias WeddingPlannerWeb.Export
  alias WeddingPlannerWeb.Export.Csv
  alias WeddingPlannerWeb.Format
  alias WeddingPlannerWeb.ReferenceFileController

  @unknown_kind_body "Unknown export."

  @doc "`GET /exports/:kind`, `?tz=` the viewer's IANA time zone."
  def show(conn, %{"kind" => kind} = params) do
    case Map.fetch(Export.exporters(), kind) do
      {:ok, module} -> send_export(conn, module, params)
      :error -> unknown_kind(conn)
    end
  end

  defp send_export(conn, module, params) do
    today = params |> Map.get("tz") |> Format.resolve_time_zone() |> TodoList.today()
    table = module.table(module.load(), today)

    conn
    |> put_resp_content_type("text/csv")
    |> put_resp_header(
      "content-disposition",
      ReferenceFileController.content_disposition(:attachment, filename(table.stem, today))
    )
    |> put_resp_header("cache-control", "no-store")
    |> send_resp(200, Csv.encode(table))
  end

  defp filename(stem, %Date{} = today) do
    "#{stem}-#{Calendar.strftime(today, "%d-%m-%Y")}.csv"
  end

  defp unknown_kind(conn) do
    conn
    |> put_resp_content_type("text/plain")
    |> send_resp(404, @unknown_kind_body)
  end
end
