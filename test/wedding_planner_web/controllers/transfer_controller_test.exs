defmodule WeddingPlannerWeb.TransferControllerTest do
  @moduledoc """
  `GET /transfer/export`, `GET /transfer/safety-copies/:name` (`DR-93`, `DR-97`, `AUTH-01`).
  """
  use WeddingPlannerWeb.ConnCase, async: false

  alias WeddingPlanner.Transfer.Document
  alias WeddingPlanner.Transfer.Export
  alias WeddingPlanner.TransferFixtures

  @moduletag :tmp_dir

  setup %{tmp_dir: tmp_dir} do
    TransferFixtures.isolate_transfer_dirs!(tmp_dir)
  end

  setup %{conn: conn} do
    data = TransferFixtures.rich!()
    %{conn: log_in_user(conn, data.scope.user), anon: conn, data: data}
  end

  defp header(conn, name) do
    case get_resp_header(conn, name) do
      [value] -> value
      other -> flunk("expected exactly one #{name} header, got #{inspect(other)}")
    end
  end

  describe "export/2 (FP-101a)" do
    test "200, application/json, no-store, an attachment filename matching the pattern, a parseable document",
         ctx do
      conn = get(ctx.conn, ~p"/transfer/export")

      assert conn.status == 200
      assert header(conn, "content-type") =~ ~r/\Aapplication\/json/
      assert header(conn, "cache-control") == "no-store"

      disposition = header(conn, "content-disposition")
      assert disposition =~ ~r/\Aattachment; /
      assert disposition =~ ~r/wedding-planner-\d{2}-\d{2}-\d{4}-\d{4}\.json/

      assert {:ok, %Document{}} = Document.parse(conn.resp_body)
    end

    test "tz shifts the filename's date to the viewer's zone (FP-101a; fail-proof: ignore tz — must fail)",
         ctx do
      # Two zones 26 hours apart (Kiritimati is UTC+14, Etc/GMT+12 is UTC-12), so their
      # calendar dates always differ, whatever moment the test happens to run at — no need
      # to pin "now" from a controller test, which can't inject a clock into the
      # controller. If `tz` were ignored, both requests would carry the same (UTC-derived)
      # date and this assertion would fail.
      conn_east = get(ctx.conn, ~p"/transfer/export?#{[tz: "Pacific/Kiritimati"]}")
      conn_west = get(ctx.conn, ~p"/transfer/export?#{[tz: "Etc/GMT+12"]}")

      east = header(conn_east, "content-disposition")
      west = header(conn_west, "content-disposition")

      assert east != west
    end

    test "an invalid tz still returns 200 (Format.resolve_time_zone/1 is total)", ctx do
      conn = get(ctx.conn, ~p"/transfer/export?tz=Nowhere/Invalid")
      assert conn.status == 200
      assert {:ok, %Document{}} = Document.parse(conn.resp_body)
    end

    test "logged out redirects to /login", ctx do
      conn = get(ctx.anon, ~p"/transfer/export")

      assert conn.status == 302
      assert redirected_to(conn) == ~p"/login?#{[return_to: "/transfer/export"]}"
    end
  end

  describe "safety_copy/2 (FP-101b)" do
    setup %{data: _data} do
      binary = [now: ~U[2026-09-25 12:05:00Z], source_host: "localhost:4000"] |> Export.build()

      {:ok, %{name: name}} =
        WeddingPlanner.Transfer.Files.write_safety_copy(
          binary,
          ~U[2026-09-25 12:05:00Z],
          "Europe/Brussels"
        )

      %{safety_copy_name: name}
    end

    test "downloads (200, attachment, application/json)", ctx do
      conn = get(ctx.conn, ~p"/transfer/safety-copies/#{ctx.safety_copy_name}")

      assert conn.status == 200
      assert header(conn, "content-type") =~ ~r/\Aapplication\/json/
      assert header(conn, "cache-control") == "no-store"
      assert header(conn, "content-disposition") =~ ~r/\Aattachment; /
      assert {:ok, %Document{}} = Document.parse(conn.resp_body)
    end

    test "a directory traversal attempt is a 404, not the file one level up (fail-proof: Path.join the raw name without safety_copy_path/1 — must fail)",
         ctx do
      # A decoy file directly in `:transfer_dir` (one level above `safety-copies/`, where
      # this route's name is expected to resolve) — a name that isn't matched by
      # `safety_copy_path/1`'s regex, so the *route* still needs the raw `name` param to
      # carry the literal ".." (Phoenix/Plug splits the raw path into segments before
      # percent-decoding each one, so `%2F` — an *encoded* slash — never introduces a
      # segment boundary; it decodes to a literal "/" only inside this single `:name`
      # segment's value, exactly the shape a traversal exploit needs).
      transfer_dir = Application.fetch_env!(:wedding_planner, :transfer_dir)
      File.write!(Path.join(transfer_dir, "secret.txt"), "TOP SECRET")

      conn = get(ctx.conn, "/transfer/safety-copies/..%2Fsecret.txt")

      assert conn.status == 404
      refute conn.resp_body =~ "TOP SECRET"
    end

    test "an unknown, valid-looking name is a 404", ctx do
      conn =
        get(
          ctx.conn,
          ~p"/transfer/safety-copies/wedding-planner-before-import-01-01-2020-0000.json"
        )

      assert conn.status == 404
    end

    test "a name with a suffix outside the pattern is a 404", ctx do
      conn = get(ctx.conn, ~p"/transfer/safety-copies/#{ctx.safety_copy_name <> ".txt"}")
      assert conn.status == 404
    end

    test "logged out redirects to /login", ctx do
      conn = get(ctx.anon, ~p"/transfer/safety-copies/#{ctx.safety_copy_name}")

      assert conn.status == 302
      assert redirected_to(conn) =~ "/login"
    end
  end

  describe "source_host/0" do
    test "the test endpoint's port (4000, Phoenix's own http scheme default) is kept, since it isn't the scheme's default (80)" do
      assert WeddingPlannerWeb.TransferController.source_host() == "localhost:4000"
    end
  end
end
