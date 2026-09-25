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

    {:ok, event} = Events.create_event(scope, %{"name" => "Reception"})
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

  describe "anonymous (AUTH-01)" do
    test "redirects to /login (FP-92g)", ctx do
      conn = get(ctx.anon, "/exports/persons")

      assert conn.status == 302
      assert redirected_to(conn) == ~p"/login?#{[return_to: "/exports/persons"]}"
      refute conn.resp_body =~ "First name"
    end
  end
end
