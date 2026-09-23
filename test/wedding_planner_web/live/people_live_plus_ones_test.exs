defmodule WeddingPlannerWeb.Live.PeopleLivePlusOnesTest do
  @moduledoc """
  `docs/modules/guests-and-events.md` `PER-10` through `PER-16`, `DR-32`/`DR-34` — +1
  management on the people-management LiveView (task 36), on top of task 35's
  `WeddingPlanner.Guests` +1 data layer. Split from `people_live_test.exs` (task 27) to
  keep each file to one slice.
  """
  use WeddingPlannerWeb.ConnCase, async: true

  import Phoenix.LiveViewTest

  alias WeddingPlanner.Accounts.Scope
  alias WeddingPlanner.Accounts.User
  alias WeddingPlanner.Guests
  alias WeddingPlanner.Guests.Person
  alias WeddingPlanner.Repo

  setup %{conn: conn} do
    user = insert_user!("Wannes")
    %{conn: log_in_user(conn, user), user: user, scope: Scope.for_user(user)}
  end

  defp row_ids(html) do
    html
    |> LazyHTML.from_fragment()
    |> LazyHTML.query("#people-rows > [id]")
    |> LazyHTML.attribute("id")
  end

  describe "add a +1 (PER-10, PER-11, PER-12)" do
    setup %{scope: scope} do
      {:ok, host} =
        Guests.create_person(scope, %{"first_name" => "Anna", "last_name" => "Peeters"})

      %{host: host}
    end

    test "adding an unnamed possible +1 inserts it directly after the host, shown as '+1 of Anna Peeters'",
         %{conn: conn, host: host} do
      {:ok, view, _html} = live(conn, ~p"/people")

      refute has_element?(view, "#person-#{host.id}-plus-one-form")
      view |> element("#person-#{host.id}-plus-one-toggle") |> render_click()
      assert has_element?(view, "#person-#{host.id}-plus-one-form")

      html =
        view
        |> form("#person-#{host.id}-plus-one-form",
          plus_one: %{
            "first_name" => "",
            "last_name" => "",
            "plus_one_status" => "possible",
            "age_category" => "adult"
          }
        )
        |> render_submit()

      [plus_one] = Guests.list_persons(%{}) |> Enum.filter(&Person.plus_one?/1)
      assert plus_one.host_id == host.id
      assert plus_one.plus_one_status == :possible
      refute Person.name_known?(plus_one)

      assert html =~ "+1 of Anna Peeters"
      refute has_element?(view, "#person-#{host.id}-plus-one-form")

      ids = row_ids(render(view))
      host_pos = Enum.find_index(ids, &(&1 == "person-#{host.id}"))
      plus_one_pos = Enum.find_index(ids, &(&1 == "person-#{plus_one.id}"))
      assert plus_one_pos == host_pos + 1
    end

    test "a host with a +1 can add another", %{conn: conn, host: host} do
      {:ok, scope} = {:ok, Scope.for_user(insert_user!("second"))}
      {:ok, _first} = Guests.add_plus_one(scope, host, %{})

      {:ok, view, _html} = live(conn, ~p"/people")

      view |> element("#person-#{host.id}-plus-one-toggle") |> render_click()

      view
      |> form("#person-#{host.id}-plus-one-form",
        plus_one: %{
          "first_name" => "",
          "last_name" => "",
          "plus_one_status" => "possible",
          "age_category" => "adult"
        }
      )
      |> render_submit()

      plus_ones = Guests.list_persons(%{}) |> Enum.filter(&Person.plus_one?/1)
      assert length(plus_ones) == 2
    end
  end

  describe "confirm a possible +1 (PER-12, single action)" do
    setup %{scope: scope} do
      {:ok, host} =
        Guests.create_person(scope, %{"first_name" => "Anna", "last_name" => "Peeters"})

      {:ok, plus_one} = Guests.add_plus_one(scope, host, %{})
      %{host: host, plus_one: plus_one}
    end

    test "one click flips the status pill tone and writes exactly one activity entry", %{
      conn: conn,
      plus_one: plus_one
    } do
      {:ok, view, _html} = live(conn, ~p"/people")

      assert has_element?(
               view,
               "##{"person-#{plus_one.id}-plus-one-status"}[data-tone='warn']"
             )

      view |> element("#person-#{plus_one.id}-confirm") |> render_click()

      assert has_element?(
               view,
               "##{"person-#{plus_one.id}-plus-one-status"}[data-tone='good']"
             )

      refute has_element?(view, "#person-#{plus_one.id}-confirm")
      assert Guests.get_person!(plus_one.id).plus_one_status == :confirmed

      {:ok, activity_view, _html} = live(conn, ~p"/activity")
      html = render(activity_view)
      assert (html |> String.split("possible → confirmed") |> length()) - 1 == 1
    end
  end

  describe "name a +1 (PER-11, PER-12, single action)" do
    setup %{scope: scope} do
      {:ok, host} =
        Guests.create_person(scope, %{"first_name" => "Anna", "last_name" => "Peeters"})

      {:ok, plus_one} = Guests.add_plus_one(scope, host, %{})
      %{host: host, plus_one: plus_one}
    end

    test "one submit names the +1 and writes exactly one activity entry", %{
      conn: conn,
      plus_one: plus_one
    } do
      {:ok, view, _html} = live(conn, ~p"/people")

      view |> element("#person-#{plus_one.id}-name-toggle") |> render_click()
      assert has_element?(view, "#person-#{plus_one.id}-name-form")

      html =
        view
        |> form("#person-#{plus_one.id}-name-form",
          name: %{"first_name" => "Tom", "last_name" => "Wils"}
        )
        |> render_submit()

      assert html =~ "Tom Wils"
      updated = Guests.get_person!(plus_one.id)
      assert updated.first_name == "Tom"
      assert updated.last_name == "Wils"
      refute has_element?(view, "#person-#{plus_one.id}-name-form")
      assert has_element?(view, "#person-#{plus_one.id}-first-name[value='Tom']")

      {:ok, activity_view, _html} = live(conn, ~p"/activity")
      html = render(activity_view)
      assert (html |> String.split("named &#39;+1 of Anna Peeters&#39;") |> length()) - 1 == 1
    end

    test "clearing both names back to blank via the normal fields makes it unnamed again", %{
      conn: conn,
      scope: scope,
      plus_one: plus_one
    } do
      {:ok, _named} = Guests.name_plus_one(scope, plus_one, %{first_name: "Tom"})

      {:ok, view, _html} = live(conn, ~p"/people")
      assert has_element?(view, "#person-#{plus_one.id}-first-name[value='Tom']")

      view
      |> element("#person-#{plus_one.id}-first-name")
      |> render_blur(%{value: ""})

      html = render(view)
      assert html =~ "+1 of Anna Peeters"
      refute Person.name_known?(Guests.get_person!(plus_one.id))
    end
  end

  describe "inherited want tier / certainty / group (PER-15, DR-32)" do
    setup %{scope: scope} do
      {:ok, family} = Guests.create_group(scope, %{"name" => "Family Peeters"})

      {:ok, host} =
        Guests.create_person(scope, %{
          "first_name" => "Anna",
          "last_name" => "Peeters",
          "want_tier" => "yes",
          "certainty" => "certain",
          "group_id" => family.id
        })

      {:ok, confirmed} = Guests.add_plus_one(scope, host, %{plus_one_status: :confirmed})
      {:ok, possible} = Guests.add_plus_one(scope, host, %{plus_one_status: :possible})

      %{family: family, host: host, confirmed: confirmed, possible: possible}
    end

    test "shows the host's want tier, certainty and group as read-only, with no select", %{
      conn: conn,
      family: family,
      confirmed: confirmed
    } do
      {:ok, view, _html} = live(conn, ~p"/people")

      assert has_element?(view, "#person-#{confirmed.id}-want-value", "Yes")
      assert has_element?(view, "#person-#{confirmed.id}-certainty-value", "Certain")
      assert has_element?(view, "#person-#{confirmed.id}-group-value", family.name)

      refute has_element?(view, "select#person-#{confirmed.id}-want")
      refute has_element?(view, "select#person-#{confirmed.id}-certainty")
      refute has_element?(view, "select#person-#{confirmed.id}-group")
    end

    test "a possible +1's certainty is capped at Uncertain", %{conn: conn, possible: possible} do
      {:ok, view, _html} = live(conn, ~p"/people")
      assert has_element?(view, "#person-#{possible.id}-certainty-value", "Uncertain")
    end

    test "changing the host's want tier live-updates the +1's read-only cell", %{
      conn: conn,
      host: host,
      confirmed: confirmed
    } do
      {:ok, view, _html} = live(conn, ~p"/people")
      assert has_element?(view, "#person-#{confirmed.id}-want-value", "Yes")

      # Each select is wrapped in its own `class="contents"` `<form>` carrying
      # `phx-change`/`phx-value-*` (DR drift fix: this LiveView version's `pushInput`
      # unconditionally requires `inputEl.form`, verified against the real browser —
      # see the moduledoc). `Phoenix.LiveViewTest`'s simulated `:change` event, targeted
      # at the `<select>` itself, only collects the element's own name/value — it does
      # not auto-merge the form's `phx-value-*` the way a real browser click does. So
      # the id/field have to be supplied explicitly here, exactly as the real browser's
      # `phx-value-*` would.
      view
      |> element("#person-#{host.id}-want-field-form")
      |> render_change(%{"id" => to_string(host.id), "field" => "want_tier", "value" => "maybe"})

      assert has_element?(view, "#person-#{confirmed.id}-want-value", "Maybe")
    end

    test "the +1's own age is independently editable", %{conn: conn, confirmed: confirmed} do
      {:ok, view, _html} = live(conn, ~p"/people")

      view
      |> element("#person-#{confirmed.id}-age-field-form")
      |> render_change(%{
        "id" => to_string(confirmed.id),
        "field" => "age_category",
        "value" => "child"
      })

      assert Guests.get_person!(confirmed.id).age_category == :child
    end
  end

  describe "grouped view (DR-34)" do
    test "the +1 appears inside its host's group section, directly under the host", %{
      conn: conn,
      scope: scope
    } do
      {:ok, family} = Guests.create_group(scope, %{"name" => "Family Peeters"})

      {:ok, host} =
        Guests.create_person(scope, %{"first_name" => "Anna", "group_id" => family.id})

      {:ok, plus_one} = Guests.add_plus_one(scope, host, %{})

      {:ok, _view, html} = live(conn, ~p"/people?view=grouped")

      ids = row_ids(html)
      group_pos = Enum.find_index(ids, &(&1 == "group-#{family.id}"))
      host_pos = Enum.find_index(ids, &(&1 == "person-#{host.id}"))
      plus_one_pos = Enum.find_index(ids, &(&1 == "person-#{plus_one.id}"))

      assert group_pos < host_pos
      assert plus_one_pos == host_pos + 1
    end
  end

  describe "filtering (DR-34)" do
    test "filtering by the +1's name shows both the host and the +1", %{
      conn: conn,
      scope: scope
    } do
      {:ok, host} =
        Guests.create_person(scope, %{"first_name" => "Anna", "last_name" => "Peeters"})

      {:ok, plus_one} = Guests.add_plus_one(scope, host, %{first_name: "Tom", last_name: "Wils"})

      {:ok, view, _html} = live(conn, ~p"/people?q=Wils")

      assert has_element?(view, "#person-#{host.id}-first-name")
      assert has_element?(view, "#person-#{plus_one.id}-first-name")
    end
  end

  describe "host deletion names the +1 (PER-16, XC-40)" do
    setup %{scope: scope} do
      {:ok, host} =
        Guests.create_person(scope, %{"first_name" => "Anna", "last_name" => "Peeters"})

      {:ok, plus_one} = Guests.add_plus_one(scope, host, %{first_name: "Tom", last_name: "Wils"})
      %{host: host, plus_one: plus_one}
    end

    test "the confirmation names the +1 and confirming removes both rows", %{
      conn: conn,
      host: host,
      plus_one: plus_one
    } do
      {:ok, view, _html} = live(conn, ~p"/people")

      view |> element("#person-#{host.id}-delete") |> render_click()

      assert has_element?(
               view,
               "#person-#{host.id}-delete-confirm-affected",
               "Also deletes their +1: Tom Wils"
             )

      view |> element("#person-#{host.id}-delete-confirm-confirm") |> render_click()

      assert_raise Ecto.NoResultsError, fn -> Guests.get_person!(host.id) end
      assert_raise Ecto.NoResultsError, fn -> Guests.get_person!(plus_one.id) end
    end

    test "deleting the +1 alone shows no extra affected references and only removes it", %{
      conn: conn,
      host: host,
      plus_one: plus_one
    } do
      {:ok, view, _html} = live(conn, ~p"/people")

      view |> element("#person-#{plus_one.id}-delete") |> render_click()

      assert has_element?(
               view,
               "#person-#{plus_one.id}-delete-confirm-title",
               "Remove 'Tom Wils'?"
             )

      assert has_element?(
               view,
               "#person-#{plus_one.id}-delete-confirm-affected",
               "Nothing else references this yet."
             )

      view |> element("#person-#{plus_one.id}-delete-confirm-confirm") |> render_click()

      assert_raise Ecto.NoResultsError, fn -> Guests.get_person!(plus_one.id) end
      assert Guests.get_person!(host.id)
    end
  end

  describe "bulk delete expands to the host's +1s (PER-07, PER-16, DR-34)" do
    test "selecting only the host names its +1 in the bulk confirmation and deletes both", %{
      conn: conn,
      scope: scope
    } do
      {:ok, host} =
        Guests.create_person(scope, %{"first_name" => "Anna", "last_name" => "Peeters"})

      {:ok, plus_one} = Guests.add_plus_one(scope, host, %{first_name: "Tom", last_name: "Wils"})

      {:ok, view, _html} = live(conn, ~p"/people")

      view |> element("#person-#{host.id}-select") |> render_click()
      view |> element("#people-bulk-delete") |> render_click()

      assert has_element?(
               view,
               "#people-bulk-delete-confirm-affected",
               "Also deletes their +1: Tom Wils"
             )

      view |> element("#people-bulk-delete-confirm-confirm") |> render_click()

      assert_raise Ecto.NoResultsError, fn -> Guests.get_person!(host.id) end
      assert_raise Ecto.NoResultsError, fn -> Guests.get_person!(plus_one.id) end
    end
  end

  describe "bulk bar wording is honest about +1s (PER-15, DR-34)" do
    test "selecting a host and its +1 notes that the +1 is skipped and inherits from its host",
         %{conn: conn, scope: scope} do
      {:ok, host} =
        Guests.create_person(scope, %{"first_name" => "Anna", "last_name" => "Peeters"})

      {:ok, plus_one} = Guests.add_plus_one(scope, host, %{})

      {:ok, view, _html} = live(conn, ~p"/people")

      view |> element("#person-#{host.id}-select") |> render_click()
      view |> element("#person-#{plus_one.id}-select") |> render_click()

      assert has_element?(
               view,
               "#people-selected-count",
               "2 selected (1 +1 — inherits from its host)"
             )
    end
  end

  describe "live updates (XC-01, DR-21)" do
    test "a +1 added by another connected view appears without reload", %{
      conn: conn,
      scope: scope,
      user: user
    } do
      {:ok, host} =
        Guests.create_person(scope, %{"first_name" => "Griet", "last_name" => "Van Acker"})

      {:ok, view_a, _html} = live(conn, ~p"/people")
      {:ok, view_b, _html} = live(log_in_user(build_conn(), user), ~p"/people")

      refute render(view_b) =~ "+1 of Griet Van Acker"

      view_a |> element("#person-#{host.id}-plus-one-toggle") |> render_click()

      view_a
      |> form("#person-#{host.id}-plus-one-form",
        plus_one: %{
          "first_name" => "",
          "last_name" => "",
          "plus_one_status" => "possible",
          "age_category" => "adult"
        }
      )
      |> render_submit()

      _ = :sys.get_state(view_b.pid)

      html = render(view_b)
      assert html =~ "+1 of Griet Van Acker"
      refute html =~ "updated"
    end
  end

  defp insert_user!(display_name) do
    %User{} |> User.changeset(%{display_name: display_name}) |> Repo.insert!()
  end
end
