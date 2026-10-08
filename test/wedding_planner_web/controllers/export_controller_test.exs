defmodule WeddingPlannerWeb.ExportControllerTest do
  @moduledoc """
  `GET /exports/:kind` (`XC-30`, `AUTH-01`, `DR-87`).
  """
  use WeddingPlannerWeb.ConnCase, async: false

  import WeddingPlanner.InvoiceFixtures
  import WeddingPlanner.OfferFixtures

  alias WeddingPlanner.Events
  alias WeddingPlanner.Guests
  alias WeddingPlanner.Log.Entry
  alias WeddingPlanner.Repo
  alias WeddingPlanner.Tasks
  alias WeddingPlannerWeb.Export

  setup %{conn: conn} do
    scope = scope_fixture()
    %{conn: log_in_user(conn, scope.user), anon: conn, scope: scope}
  end

  defp header(conn, name) do
    case get_resp_header(conn, name) do
      [value] -> value
      other -> flunk("expected exactly one #{name} header, got #{inspect(other)}")
    end
  end

  # At least one row of every registered kind (persons, events, invoices, tasks).
  defp seed_one_of_each!(scope) do
    {:ok, person} =
      Guests.create_person(scope, %{"first_name" => "Anna", "last_name" => "Peeters"})

    {:ok, event} = Events.create_event(scope, %{"couple_attends" => false, "name" => "Reception"})
    category = category_fixture(scope)
    invoice = invoice_fixture(scope, category)
    {:ok, task} = Tasks.create_task(scope, %{"title" => "Book flowers"})

    %{person: person, event: event, category: category, invoice: invoice, task: task}
  end

  describe "signed in" do
    test "200, text/csv, attachment filename, BOM + header row", ctx do
      seed_one_of_each!(ctx.scope)

      conn = get(ctx.conn, ~p"/exports/persons?tz=Europe/Brussels")

      assert conn.status == 200
      assert header(conn, "content-type") == "text/csv; charset=utf-8"
      assert header(conn, "cache-control") == "no-store"

      disposition = header(conn, "content-disposition")
      assert disposition =~ ~r/\Aattachment; /
      assert disposition =~ ~r/filename="persons-\d{2}-\d{2}-\d{4}\.csv"/
      assert disposition =~ ~r/filename\*=UTF-8''persons-\d{2}-\d{2}-\d{4}\.csv/

      assert :binary.part(conn.resp_body, 0, 3) == <<0xEF, 0xBB, 0xBF>>
      assert conn.resp_body =~ "First name;Last name;Display name"
    end

    test "an invalid tz still returns 200 (Format.resolve_time_zone/1 is total)", ctx do
      seed_one_of_each!(ctx.scope)
      conn = get(ctx.conn, ~p"/exports/persons?tz=Nowhere/Invalid")
      assert conn.status == 200
      assert header(conn, "content-disposition") =~ ~r/persons-\d{2}-\d{2}-\d{4}\.csv/
    end

    test "each of the four registered kinds returns 200 against a DB with a row of that kind",
         ctx do
      seed_one_of_each!(ctx.scope)

      for kind <- ["persons", "events", "invoices", "tasks"] do
        conn = get(ctx.conn, ~p"/exports/#{kind}")
        assert conn.status == 200, "expected #{kind} to return 200, got #{conn.status}"
        assert :binary.part(conn.resp_body, 0, 3) == <<0xEF, 0xBB, 0xBF>>
      end
    end

    test "an unknown kind is a 404, text/plain", ctx do
      conn = get(ctx.conn, ~p"/exports/nope")

      assert conn.status == 404
      assert header(conn, "content-type") =~ ~r/\Atext\/plain/
      assert conn.resp_body == "Unknown export."
    end

    test "no activity entry is written by an export", ctx do
      seed_one_of_each!(ctx.scope)
      before_count = Repo.aggregate(Entry, :count)

      for kind <- ["persons", "events", "invoices", "tasks"] do
        conn = get(ctx.conn, ~p"/exports/#{kind}")
        assert conn.status == 200
      end

      after_count = Repo.aggregate(Entry, :count)
      assert after_count == before_count
    end
  end

  describe "computed exports (headcount, offers, budget)" do
    setup %{scope: scope} do
      {:ok, event} =
        Events.create_event(scope, %{"couple_attends" => false, "name" => "Reception"})

      category = category_fixture(scope)
      offer = offer_fixture(scope, category)
      %{event: event, category: category, offer: offer}
    end

    # FP-94c: comment out `"budget" => Export.Budget` in
    # `WeddingPlannerWeb.Export.exporters/0` — the `budget` iteration below then
    # receives a 404, and this test fails.
    test "headcount, offers and budget each return 200, BOM, and their own header row",
         ctx do
      for {kind, mod} <- [
            {"headcount", Export.Headcount},
            {"offers", Export.Offers},
            {"budget", Export.Budget}
          ] do
        conn = get(ctx.conn, ~p"/exports/#{kind}")

        assert conn.status == 200, "expected #{kind} to return 200, got #{conn.status}"

        body = conn.resp_body
        assert :binary.part(body, 0, 3) == <<0xEF, 0xBB, 0xBF>>

        expected_headers = mod.load() |> mod.table(~D[2026-09-25]) |> Map.fetch!(:headers)
        without_bom = :binary.part(body, 3, byte_size(body) - 3)
        [first_line | _] = String.split(without_bom, "\r\n")

        assert first_line == Enum.join(expected_headers, ";"),
               "#{kind}: expected header row #{inspect(Enum.join(expected_headers, ";"))}, " <>
                 "got #{inspect(first_line)}"
      end
    end
  end

  describe "anonymous (AUTH-01)" do
    test "redirects to /login (FP-92g)", ctx do
      conn = get(ctx.anon, "/exports/persons")

      assert conn.status == 302
      assert redirected_to(conn) == ~p"/login?#{[return_to: "/exports/persons"]}"
      refute conn.resp_body =~ "First name"
    end
  end
end
