defmodule WeddingPlannerWeb.ReferenceFileControllerTest do
  @moduledoc """
  `WeddingPlannerWeb.ReferenceFileController` — authenticated serving of uploaded
  reference files (`docs/04-cross-cutting.md` `XC-22`, `XC-23`; `AUTH-01`; `DR-29`,
  `DR-30`).

  References are created through `References.create_file_reference/4` with the stand-in
  owner (`DR-28`, `WeddingPlanner.ReferenceFixtures.owner/0`), so every file on disk was
  put there by the real `Storage`. `async: false` because the tests write to
  `:uploads_dir`; everything they add is removed on exit
  (`ReferenceFixtures.track_uploads_dir/0`).
  """
  use WeddingPlannerWeb.ConnCase, async: false

  import ExUnit.CaptureLog
  import WeddingPlanner.ReferenceFixtures

  alias WeddingPlanner.Accounts.Scope
  alias WeddingPlanner.Accounts.User
  alias WeddingPlanner.References
  alias WeddingPlanner.References.Storage
  alias WeddingPlanner.Repo
  alias WeddingPlannerWeb.ReferenceFileController

  @missing_body "This file is missing from storage. If the app was recently restored from backup, it may not have been synced yet."

  setup %{conn: conn} do
    user = %User{} |> User.changeset(%{display_name: "Wannes"}) |> Repo.insert!()
    track_uploads_dir()

    %{
      anon: conn,
      conn: log_in_user(conn, user),
      scope: Scope.for_user(user),
      src: tmp_upload_dir!()
    }
  end

  defp upload!(ctx, kind, name) do
    {:ok, reference} =
      References.create_file_reference(
        ctx.scope,
        owner(),
        %{},
        write_fixture!(ctx.src, kind, name)
      )

    reference
  end

  defp header(conn, name) do
    case get_resp_header(conn, name) do
      [value] -> value
      other -> flunk("expected exactly one #{name} header, got #{inspect(other)}")
    end
  end

  describe "show/2 (inline, XC-22)" do
    test "a PNG is served inline with its bytes and the sniffed type", ctx do
      reference = upload!(ctx, :png, "photo.png")

      conn = get(ctx.conn, ~p"/references/#{reference.id}/file")

      assert conn.status == 200
      assert header(conn, "content-type") == "image/png"
      assert header(conn, "content-disposition") =~ ~r/\Ainline; /
      assert conn.resp_body == bytes(:png)
    end

    test "a PDF is served inline as application/pdf", ctx do
      reference = upload!(ctx, :pdf, "quote.pdf")

      conn = get(ctx.conn, ~p"/references/#{reference.id}/file")

      assert conn.status == 200
      assert header(conn, "content-type") == "application/pdf"
      assert header(conn, "content-disposition") =~ ~r/\Ainline; /
      assert conn.resp_body == bytes(:pdf)
    end

    test "a PNG uploaded as x.jpg is served as image/png — the sniffed type wins", ctx do
      reference = upload!(ctx, :png, "x.jpg")

      conn = get(ctx.conn, ~p"/references/#{reference.id}/file")

      assert conn.status == 200
      assert header(conn, "content-type") == "image/png"
      assert conn.resp_body == bytes(:png)
    end
  end

  describe "download/2 (attachment, XC-22)" do
    test "is an attachment under the original, non-ASCII filename", ctx do
      reference = upload!(ctx, :pdf, "Offerte_Château.pdf")

      conn = get(ctx.conn, ~p"/references/#{reference.id}/download")

      assert conn.status == 200
      assert header(conn, "content-type") == "application/pdf"
      disposition = header(conn, "content-disposition")
      assert disposition =~ ~r/\Aattachment; /
      assert disposition =~ ~s(; filename="Offerte_Chateau.pdf")
      assert disposition =~ "; filename*=UTF-8''Offerte_Ch%C3%A2teau.pdf"
      assert conn.resp_body == bytes(:pdf)
    end
  end

  describe "headers on both routes (DR-30)" do
    for route <- ["file", "download"] do
      test "#{route}: nosniff and a private cache-control", ctx do
        reference = upload!(ctx, :jpeg, "venue.jpg")

        conn = get(ctx.conn, "/references/#{reference.id}/#{unquote(route)}")

        assert conn.status == 200
        assert header(conn, "x-content-type-options") == "nosniff"
        assert header(conn, "cache-control") == "private, max-age=3600"
      end
    end
  end

  describe "anonymous (AUTH-01)" do
    for route <- ["file", "download"] do
      test "#{route}: redirects to /login and never sends the bytes", ctx do
        reference = upload!(ctx, :png, "photo.png")
        path = "/references/#{reference.id}/#{unquote(route)}"

        conn = get(ctx.anon, path)

        assert conn.status == 302
        assert redirected_to(conn) == ~p"/login?#{[return_to: path]}"
        refute conn.resp_body =~ bytes(:png)
        assert get_resp_header(conn, "content-disposition") == []
      end
    end
  end

  describe "404s (DR-30)" do
    test "an unknown id", ctx do
      for route <- ["file", "download"] do
        conn = get(ctx.conn, "/references/999999/#{route}")
        assert conn.status == 404
      end
    end

    test "a non-integer id", ctx do
      conn = get(ctx.conn, "/references/abc/file")
      assert conn.status == 404
    end

    test "a url-kind reference has no file", ctx do
      {:ok, reference} =
        References.create_url_reference(ctx.scope, owner(), %{
          "label" => "Venue website",
          "url" => "https://example.com/venue"
        })

      for route <- ["file", "download"] do
        conn = get(ctx.conn, "/references/#{reference.id}/#{route}")
        assert conn.status == 404
      end
    end

    test "a row whose file is missing from disk: 404 with the explanation, logged", ctx do
      reference = upload!(ctx, :pdf, "quote.pdf")
      File.rm!(Storage.path_for(reference))

      for route <- ["file", "download"] do
        log =
          capture_log(fn ->
            conn = get(ctx.conn, "/references/#{reference.id}/#{route}")

            assert conn.status == 404
            assert conn.resp_body == @missing_body
            assert header(conn, "content-type") =~ ~r/\Atext\/plain/
            assert get_resp_header(conn, "content-disposition") == []
          end)

        assert log =~ "[warning]"
        assert log =~ "reference #{reference.id} file missing from storage"
      end
    end
  end

  describe "content_disposition/2" do
    test "a plain ASCII name is unchanged in both parts" do
      assert ReferenceFileController.content_disposition(:inline, "quote-2026.pdf") ==
               ~s(inline; filename="quote-2026.pdf"; filename*=UTF-8''quote-2026.pdf)
    end

    test "quotes, backslashes, spaces and non-Latin script" do
      value = ReferenceFileController.content_disposition(:attachment, ~s(a "b" \\ 婚礼.png))

      assert value ==
               ~s(attachment; filename="a _b_ _ __.png"; filename*=UTF-8''a%20%22b%22%20%5C%20%E5%A9%9A%E7%A4%BC.png)
    end

    test "characters that would break the header are encoded in filename*" do
      value = ReferenceFileController.content_disposition(:inline, "a;b,c'd%e.pdf")

      assert value =~ ~s(filename="a;b,c'd%e.pdf")
      assert value =~ "filename*=UTF-8''a%3Bb%2Cc%27d%25e.pdf"
    end
  end
end
