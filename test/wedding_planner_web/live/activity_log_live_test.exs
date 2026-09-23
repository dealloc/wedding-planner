defmodule WeddingPlannerWeb.Live.ActivityLogLiveTest do
  @moduledoc """
  The global activity log LiveView (task 20; `docs/04-cross-cutting.md` `XC-11`, `XC-12`,
  `XC-01`, `XC-13`, `NFR-22`, `NFR-23`).
  """
  use WeddingPlannerWeb.ConnCase, async: true

  import Phoenix.LiveViewTest

  alias WeddingPlanner.Accounts.Scope
  alias WeddingPlanner.Accounts.User
  alias WeddingPlanner.Log
  alias WeddingPlanner.Realtime
  alias WeddingPlanner.Repo
  alias WeddingPlannerWeb.Format

  setup %{conn: conn} do
    wannes = insert_user!("Wannes")
    partner = insert_user!("Partner")

    %{
      conn: log_in_user(conn, wannes),
      wannes: wannes,
      partner: partner,
      wannes_scope: Scope.for_user(wannes),
      partner_scope: Scope.for_user(partner)
    }
  end

  describe "authentication" do
    test "an unauthenticated request redirects to /login", %{} do
      conn = Phoenix.ConnTest.build_conn()
      conn = get(conn, ~p"/activity")

      assert redirected_to(conn) == "/login?return_to=%2Factivity"
    end
  end

  describe "mounting and rendering" do
    test "shows an empty state when there is no activity yet", %{conn: conn} do
      {:ok, view, html} = live(conn, ~p"/activity")

      assert html =~ "Activity log"
      assert has_element?(view, "#activity-log-empty")
    end

    test "renders each entry by a stable DOM id, newest first", %{
      conn: conn,
      wannes_scope: scope
    } do
      {:ok, first} = Log.entry(scope, {:person, 1}, "First thing happened")
      {:ok, second} = Log.entry(scope, {:person, 2}, "Second thing happened")

      {:ok, view, _html} = live(conn, ~p"/activity")

      assert has_element?(view, "#activity-entry-#{first.id}", "First thing happened")
      assert has_element?(view, "#activity-entry-#{second.id}", "Second thing happened")

      # Newest first: the second entry's row comes before the first's in the stream.
      html = render(view)
      {second_pos, _} = :binary.match(html, "activity-entry-#{second.id}")
      {first_pos, _} = :binary.match(html, "activity-entry-#{first.id}")
      assert second_pos < first_pos
    end

    test "shows the acting user and a dd/mm/yyyy local timestamp (NFR-22, NFR-23)", %{
      conn: conn,
      wannes_scope: scope,
      wannes: wannes
    } do
      {:ok, entry} = Log.entry(scope, {:person, 1}, "Something happened")

      {:ok, view, _html} = live(conn, ~p"/activity")

      assert has_element?(view, "#activity-entry-#{entry.id}", wannes.display_name)
      expected = Format.datetime(entry.inserted_at, Format.default_time_zone())
      assert has_element?(view, "#activity-entry-#{entry.id} time", expected)
    end

    test "an entry for a deleted entity still renders (XC-10)", %{
      conn: conn,
      wannes_scope: scope,
      wannes: wannes
    } do
      {:ok, passkey} =
        %WeddingPlanner.Accounts.Passkey{user_id: wannes.id}
        |> WeddingPlanner.Accounts.Passkey.registration_changeset(%{
          credential_id: <<9, 9, 9>>,
          public_key: <<1, 2, 3>>,
          name: "Old phone",
          registered_at: DateTime.utc_now() |> DateTime.truncate(:second)
        })
        |> Repo.insert()

      {:ok, entry} =
        Log.entry(scope, {:passkey, passkey.id}, "Wannes revoked passkey 'Old phone'")

      Repo.delete!(passkey)

      {:ok, view, _html} = live(conn, ~p"/activity")
      assert has_element?(view, "#activity-entry-#{entry.id}")
    end
  end

  describe "filters (XC-11)" do
    test "filtering by user changes the visible set", %{
      conn: conn,
      wannes_scope: wannes_scope,
      partner_scope: partner_scope,
      wannes: wannes
    } do
      {:ok, by_wannes} = Log.entry(wannes_scope, {:person, 1}, "By Wannes")
      {:ok, by_partner} = Log.entry(partner_scope, {:person, 2}, "By Partner")

      {:ok, view, _html} = live(conn, ~p"/activity")
      assert has_element?(view, "#activity-entry-#{by_wannes.id}")
      assert has_element?(view, "#activity-entry-#{by_partner.id}")

      view
      |> form("#activity-filters", filter: %{"user_id" => to_string(wannes.id)})
      |> render_change()

      assert has_element?(view, "#activity-entry-#{by_wannes.id}")
      refute has_element?(view, "#activity-entry-#{by_partner.id}")
    end

    test "filtering by entity type changes the visible set", %{
      conn: conn,
      wannes_scope: scope
    } do
      {:ok, person_entry} = Log.entry(scope, {:person, 1}, "Person entry")
      {:ok, invoice_entry} = Log.entry(scope, {:invoice, 1}, "Invoice entry")

      {:ok, view, _html} = live(conn, ~p"/activity")
      assert has_element?(view, "#activity-entry-#{person_entry.id}")
      assert has_element?(view, "#activity-entry-#{invoice_entry.id}")

      view
      |> form("#activity-filters", filter: %{"entity_type" => "person"})
      |> render_change()

      assert has_element?(view, "#activity-entry-#{person_entry.id}")
      refute has_element?(view, "#activity-entry-#{invoice_entry.id}")
    end

    test "filtering by date range changes the visible set", %{
      conn: conn,
      wannes_scope: scope
    } do
      {:ok, entry} = Log.entry(scope, {:person, 1}, "Today's entry")
      today = DateTime.to_date(entry.inserted_at)
      yesterday = Date.add(today, -1)
      tomorrow = Date.add(today, 1)

      {:ok, view, _html} = live(conn, ~p"/activity")
      assert has_element?(view, "#activity-entry-#{entry.id}")

      # A range that excludes today hides the entry.
      view
      |> form("#activity-filters",
        filter: %{"from" => Date.to_iso8601(yesterday), "to" => Date.to_iso8601(yesterday)}
      )
      |> render_change()

      refute has_element?(view, "#activity-entry-#{entry.id}")

      # A range that includes today shows it again.
      view
      |> form("#activity-filters",
        filter: %{"from" => Date.to_iso8601(today), "to" => Date.to_iso8601(tomorrow)}
      )
      |> render_change()

      assert has_element?(view, "#activity-entry-#{entry.id}")
    end
  end

  describe "bulk action collapse/expand (XC-12)" do
    test "children are collapsed under the summary by default and expand on interaction", %{
      conn: conn,
      wannes_scope: scope
    } do
      {:ok, :done} =
        Log.action(scope, "Wannes set 2 people to invited", fn ->
          {:ok, _} = Log.entry(scope, {:person, 1}, "Person 1 set to invited")
          {:ok, _} = Log.entry(scope, {:person, 2}, "Person 2 set to invited")
          :done
        end)

      [summary] = Log.Query.list()
      [child1, child2] = Log.Query.children(summary.id)

      {:ok, view, _html} = live(conn, ~p"/activity")

      assert has_element?(view, "#activity-entry-#{summary.id}", "Wannes set 2 people to invited")
      assert has_element?(view, "#activity-toggle-#{summary.id}", "Show 2 affected entities")
      refute has_element?(view, "#activity-children-#{summary.id}")
      refute has_element?(view, "#activity-child-#{child1.id}")
      refute has_element?(view, "#activity-child-#{child2.id}")

      view |> element("#activity-toggle-#{summary.id}") |> render_click()

      assert has_element?(view, "#activity-children-#{summary.id}")
      assert has_element?(view, "#activity-child-#{child1.id}", "Person 1 set to invited")
      assert has_element?(view, "#activity-child-#{child2.id}", "Person 2 set to invited")
      assert has_element?(view, "#activity-toggle-#{summary.id}", "Hide 2 affected entities")

      # Collapsing again removes the children from the DOM.
      view |> element("#activity-toggle-#{summary.id}") |> render_click()
      refute has_element?(view, "#activity-children-#{summary.id}")
    end

    test "a standalone entry never gets a toggle button", %{conn: conn, wannes_scope: scope} do
      {:ok, entry} = Log.entry(scope, {:person, 1}, "Standalone entry")

      {:ok, view, _html} = live(conn, ~p"/activity")

      assert has_element?(view, "#activity-entry-#{entry.id}")
      refute has_element?(view, "#activity-toggle-#{entry.id}")
    end
  end

  describe "live updates (XC-01)" do
    test "a new entry matching the active filter appears without a refresh", %{
      conn: conn,
      wannes_scope: scope,
      wannes: wannes
    } do
      {:ok, view, _html} = live(conn, ~p"/activity")

      view
      |> form("#activity-filters", filter: %{"user_id" => to_string(wannes.id)})
      |> render_change()

      {:ok, entry} = Log.entry(scope, {:person, 1}, "Live entry")
      _ = :sys.get_state(view.pid)

      assert has_element?(view, "#activity-entry-#{entry.id}", "Live entry")
    end

    test "a new entry not matching the active filter does not appear", %{
      conn: conn,
      wannes_scope: wannes_scope,
      partner_scope: partner_scope,
      wannes: wannes
    } do
      {:ok, view, _html} = live(conn, ~p"/activity")

      view
      |> form("#activity-filters", filter: %{"user_id" => to_string(wannes.id)})
      |> render_change()

      {:ok, entry} = Log.entry(partner_scope, {:person, 1}, "Not visible to this filter")
      _ = :sys.get_state(view.pid)

      refute has_element?(view, "#activity-entry-#{entry.id}")

      # Sanity check the entry was really written (not just a filter-matching accident).
      assert wannes_scope.user.id != entry.user_id
    end

    test "bulk action children arriving live update an already-shown, expanded summary", %{
      conn: conn,
      wannes_scope: scope
    } do
      {:ok, view, _html} = live(conn, ~p"/activity")

      {:ok, :done} =
        Log.action(scope, "Bulk action in progress", fn ->
          {:ok, _} = Log.entry(scope, {:person, 1}, "First child arrives live")
          :done
        end)

      _ = :sys.get_state(view.pid)

      [summary] = Log.Query.list()
      assert has_element?(view, "#activity-toggle-#{summary.id}", "Show 1 affected entity")

      view |> element("#activity-toggle-#{summary.id}") |> render_click()
      [child] = Log.Query.children(summary.id)
      assert has_element?(view, "#activity-child-#{child.id}", "First child arrives live")
    end

    test "a broadcast for an unrelated resource is ignored", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/activity")

      Realtime.broadcast_change(:shell_demo, {:updated, %{message: "unrelated"}})
      _ = :sys.get_state(view.pid)

      assert has_element?(view, "#activity-log-empty")
    end
  end

  defp insert_user!(display_name) do
    %User{} |> User.changeset(%{display_name: display_name}) |> Repo.insert!()
  end
end
