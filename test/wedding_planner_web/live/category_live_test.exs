defmodule WeddingPlannerWeb.Live.CategoryLiveTest do
  @moduledoc """
  `docs/modules/offers-and-comparison.md` `CST-02`, `CST-03`, `CST-04`, `CST-06`,
  `CST-51`; `D-34`, `DR-26` Q12, Q14; `XC-01`, `XC-10`, `XC-40` — the category page
  LiveView (task 29), where services are managed banded by wanted priority.
  """
  use WeddingPlannerWeb.ConnCase, async: true

  import Phoenix.LiveViewTest

  alias WeddingPlanner.Accounts.Scope
  alias WeddingPlanner.Accounts.User
  alias WeddingPlanner.Categories
  alias WeddingPlanner.Repo

  setup %{conn: conn} do
    user = insert_user!("Wannes")
    %{conn: log_in_user(conn, user), user: user, scope: Scope.for_user(user)}
  end

  describe "authentication" do
    test "an unauthenticated request redirects to /login" do
      {:ok, category} =
        WeddingPlanner.Repo.insert(%WeddingPlanner.Categories.Category{
          name: "Venue",
          sort_order: 0
        })

      conn = Phoenix.ConnTest.build_conn()
      conn = get(conn, ~p"/categories/#{category.id}")

      assert redirected_to(conn) == "/login?return_to=%2Fcategories%2F#{category.id}"
    end
  end

  describe "show" do
    setup %{scope: scope} do
      {:ok, category} = Categories.create_category(scope, %{"name" => "Venue"})
      %{category: category}
    end

    test "shows the category name, target and an empty band", %{conn: conn, category: category} do
      {:ok, view, html} = live(conn, ~p"/categories/#{category.id}")

      assert html =~ "Venue"
      assert has_element?(view, "#category-target", "No target")
      assert has_element?(view, "#band-must-have", "No services")
      assert has_element?(view, "#band-nice-to-have", "No services")
      assert has_element?(view, "#band-not-wanted", "No services")
    end
  end

  describe "add service (CST-02, CST-51)" do
    setup %{scope: scope} do
      {:ok, category} = Categories.create_category(scope, %{"name" => "Venue"})
      %{category: category}
    end

    test "a new service defaults to nice-to-have and appears in that band", %{
      conn: conn,
      category: category
    } do
      {:ok, view, _html} = live(conn, ~p"/categories/#{category.id}")

      view
      |> form("#add-service-form", service: %{"name" => "Catering"})
      |> render_submit()

      assert has_element?(view, "#band-nice-to-have", "Catering")
      refute has_element?(view, "#band-must-have", "Catering")
    end

    test "a service added as must-have appears in the must-have band", %{
      conn: conn,
      category: category
    } do
      {:ok, view, _html} = live(conn, ~p"/categories/#{category.id}")

      view
      |> form("#add-service-form",
        service: %{"name" => "Catering", "wanted_priority" => "must_have"}
      )
      |> render_submit()

      assert has_element?(view, "#band-must-have", "Catering")
    end

    test "a blank name is rejected with an inline error", %{conn: conn, category: category} do
      {:ok, view, _html} = live(conn, ~p"/categories/#{category.id}")

      html =
        view
        |> form("#add-service-form", service: %{"name" => ""})
        |> render_submit()

      assert html =~ "can&#39;t be blank"
    end
  end

  describe "changing priority moves the row between bands (CST-51)" do
    setup %{scope: scope} do
      {:ok, category} = Categories.create_category(scope, %{"name" => "Venue"})
      {:ok, service} = Categories.create_service(scope, category, %{"name" => "Catering"})
      %{category: category, service: service}
    end

    test "selecting must-have moves the row out of nice-to-have immediately", %{
      conn: conn,
      category: category,
      service: service
    } do
      {:ok, view, _html} = live(conn, ~p"/categories/#{category.id}")

      assert has_element?(view, "#band-nice-to-have", "Catering")

      view
      |> element("#service-#{service.id}-priority-form")
      |> render_change(%{"wanted_priority" => "must_have"})

      assert has_element?(view, "#band-must-have", "Catering")
      refute has_element?(view, "#band-nice-to-have", "Catering")
      assert Categories.get_service!(service.id).wanted_priority == :must_have
    end
  end

  describe "inline rename (blur commit)" do
    setup %{scope: scope} do
      {:ok, category} = Categories.create_category(scope, %{"name" => "Venue"})
      {:ok, service} = Categories.create_service(scope, category, %{"name" => "Catering"})
      %{category: category, service: service}
    end

    test "renaming writes exactly one activity entry and shows the new name", %{
      conn: conn,
      category: category,
      service: service
    } do
      {:ok, view, _html} = live(conn, ~p"/categories/#{category.id}")

      view
      |> form("#service-#{service.id}-rename-form", service: %{"name" => "Catering & Bar"})
      |> render_submit()

      assert has_element?(view, "#band-nice-to-have", "Catering & Bar")
      assert Categories.get_service!(service.id).name == "Catering & Bar"

      entries =
        Repo.all(WeddingPlanner.Log.Entry)
        |> Enum.filter(&(&1.description =~ "changed the name"))

      assert length(entries) == 1
    end

    test "a clashing rename shows the error and the merge offer", %{
      conn: conn,
      scope: scope,
      category: category,
      service: service
    } do
      {:ok, _sound} = Categories.create_service(scope, category, %{"name" => "Sound"})

      {:ok, view, _html} = live(conn, ~p"/categories/#{category.id}")

      html =
        view
        |> form("#service-#{service.id}-rename-form", service: %{"name" => "sound"})
        |> render_submit()

      assert html =~ "merge instead"
      assert has_element?(view, "#service-#{service.id}-merge-select")
    end
  end

  describe "merge (CST-04, DR-26 Q14)" do
    setup %{scope: scope} do
      {:ok, category} = Categories.create_category(scope, %{"name" => "Venue"})

      {:ok, survivor} =
        Categories.create_service(scope, category, %{
          "name" => "Sound",
          "wanted_priority" => "must_have"
        })

      {:ok, absorbed} = Categories.create_service(scope, category, %{"name" => "Sound system"})

      %{category: category, survivor: survivor, absorbed: absorbed}
    end

    test "no merge control is shown when there is only one service", %{scope: scope} do
      {:ok, category} = Categories.create_category(scope, %{"name" => "Catering"})
      {:ok, only} = Categories.create_service(scope, category, %{"name" => "Buffet"})

      conn = build_conn() |> log_in_user(insert_user!("Solo"))
      {:ok, view, _html} = live(conn, ~p"/categories/#{category.id}")

      refute has_element?(view, "#service-#{only.id}-merge-select")
    end

    test "merging removes the absorbed service and keeps the survivor's name and priority", %{
      conn: conn,
      category: category,
      survivor: survivor,
      absorbed: absorbed
    } do
      {:ok, view, _html} = live(conn, ~p"/categories/#{category.id}")

      view
      |> form("#service-#{absorbed.id}-merge-form", %{"survivor_id" => to_string(survivor.id)})
      |> render_submit()

      assert has_element?(view, "#service-#{absorbed.id}-merge-confirm")

      view
      |> element("#service-#{absorbed.id}-merge-confirm-confirm")
      |> render_click()

      refute has_element?(view, "#service-#{absorbed.id}-name-input")
      assert_raise Ecto.NoResultsError, fn -> Categories.get_service!(absorbed.id) end

      reloaded = Categories.get_service!(survivor.id)
      assert reloaded.name == "Sound"
      assert reloaded.wanted_priority == :must_have
      assert has_element?(view, "#band-must-have", "Sound")
    end

    test "cancelling a merge request leaves both services in place", %{
      conn: conn,
      category: category,
      survivor: survivor,
      absorbed: absorbed
    } do
      {:ok, view, _html} = live(conn, ~p"/categories/#{category.id}")

      view
      |> form("#service-#{absorbed.id}-merge-form", %{"survivor_id" => to_string(survivor.id)})
      |> render_submit()

      view |> element("#service-#{absorbed.id}-merge-confirm-cancel") |> render_click()

      refute has_element?(view, "#service-#{absorbed.id}-merge-confirm")
      assert Categories.get_service!(absorbed.id)
      assert Categories.get_service!(survivor.id)
    end
  end

  describe "delete (CST-06, D-34, DR-26 Q12, XC-40)" do
    setup %{scope: scope} do
      {:ok, category} = Categories.create_category(scope, %{"name" => "Venue"})
      {:ok, service} = Categories.create_service(scope, category, %{"name" => "Catering"})
      %{category: category, service: service}
    end

    test "deletes a line-less service after confirmation", %{
      conn: conn,
      category: category,
      service: service
    } do
      {:ok, view, _html} = live(conn, ~p"/categories/#{category.id}")

      view |> element("#service-#{service.id}-delete") |> render_click()
      assert has_element?(view, "#service-#{service.id}-delete-confirm-confirm")

      view |> element("#service-#{service.id}-delete-confirm-confirm") |> render_click()

      assert_raise Ecto.NoResultsError, fn -> Categories.get_service!(service.id) end
      refute has_element?(view, "#service-#{service.id}-name-input")
    end

    test "cancelling leaves the service in place", %{
      conn: conn,
      category: category,
      service: service
    } do
      {:ok, view, _html} = live(conn, ~p"/categories/#{category.id}")

      view |> element("#service-#{service.id}-delete") |> render_click()
      view |> element("#service-#{service.id}-delete-confirm-cancel") |> render_click()

      refute has_element?(view, "#service-#{service.id}-delete-confirm")
      assert Categories.get_service!(service.id)
    end

    test "when the service has offer lines, the confirmation offers merge/set-not-wanted, no delete (DR-26 Q12, DR-41)",
         %{conn: conn, category: category, service: service, scope: scope} do
      {:ok, offer} =
        WeddingPlanner.Offers.create_offer(scope, category, %{"vendor_name" => "Venue A"})

      {:ok, _line} =
        WeddingPlanner.Offers.create_line(scope, offer, %{
          "service_id" => service.id,
          "state" => "included"
        })

      {:ok, _other} = Categories.create_service(scope, category, %{"name" => "Sound"})

      {:ok, view, _html} = live(conn, ~p"/categories/#{category.id}")

      view |> element("#service-#{service.id}-delete") |> render_click()

      refute has_element?(view, "#service-#{service.id}-delete-confirm-confirm")
      assert has_element?(view, "#service-#{service.id}-delete-confirm-set-not-wanted")
      assert has_element?(view, "#service-#{service.id}-merge-select")

      view
      |> element("#service-#{service.id}-delete-confirm-set-not-wanted")
      |> render_click()

      assert Categories.get_service!(service.id).wanted_priority == :not_wanted
      assert has_element?(view, "#band-not-wanted", "Catering")
    end

    test "the delete still writes an activity entry, visible in the service's own history", %{
      conn: conn,
      category: category,
      service: service
    } do
      {:ok, view, _html} = live(conn, ~p"/categories/#{category.id}")

      view |> element("#service-#{service.id}-delete") |> render_click()
      view |> element("#service-#{service.id}-delete-confirm-confirm") |> render_click()

      {:ok, activity_view, _html} = live(conn, ~p"/activity")
      assert has_element?(activity_view, "#activity-log", "deleted service 'Catering'")
    end
  end

  describe "live updates (XC-01, XC-02)" do
    test "a change made through Categories in the test process appears without a refresh, no change indicator",
         %{conn: conn, scope: scope} do
      {:ok, category} = Categories.create_category(scope, %{"name" => "Venue"})
      {:ok, service} = Categories.create_service(scope, category, %{"name" => "Catering"})

      {:ok, view, _html} = live(conn, ~p"/categories/#{category.id}")

      assert has_element?(view, "#band-nice-to-have", "Catering")

      {:ok, _} =
        Categories.update_service(scope, service, %{"wanted_priority" => "must_have"})

      _ = :sys.get_state(view.pid)

      assert has_element?(view, "#band-must-have", "Catering")
      refute has_element?(view, "#band-nice-to-have", "Catering")
      # DR-21/XC-02: no highlight/badge marks the row as changed — the only assertion
      # available is the absence of any such marker class, which no markup in this
      # LiveView ever emits (confirmed by reading the module: no "highlight"/"badge"/
      # "just-updated" class exists anywhere in it).
      refute render(view) =~ "just-updated"
    end
  end

  defp insert_user!(display_name) do
    %User{} |> User.changeset(%{display_name: display_name}) |> Repo.insert!()
  end
end
