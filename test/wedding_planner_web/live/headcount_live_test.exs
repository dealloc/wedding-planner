defmodule WeddingPlannerWeb.Live.HeadcountLiveTest do
  @moduledoc """
  `/headcount` (task 61; `docs/modules/headcount.md` `HC-03`, `HC-07`, `HC-08`, `HC-09`;
  `DR-55`) — real database rows throughout (`WeddingPlanner.NormativeGuests`) →
  `WeddingPlanner.Valuation.Snapshot.load/1` → the production engine, no `headcount:`
  seam, the same discipline `WeddingPlannerWeb.Live.OfferLiveCostTest` uses.
  """
  use WeddingPlannerWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias WeddingPlanner.Accounts.Scope
  alias WeddingPlanner.Accounts.User
  alias WeddingPlanner.Events
  alias WeddingPlanner.Guests
  alias WeddingPlanner.Invitations
  alias WeddingPlanner.NormativeGuests
  alias WeddingPlanner.Presets
  alias WeddingPlanner.Repo
  alias WeddingPlanner.Valuation.Headcount
  alias WeddingPlanner.Valuation.Snapshot

  setup %{conn: conn} do
    user = insert_user!("Wannes")
    %{conn: log_in_user(conn, user), user: user, scope: Scope.for_user(user)}
  end

  defp preset_named(name), do: Enum.find(Presets.list_presets(), &(&1.name == name))

  # `Headcount.evaluate/3` takes a `Valuation.Preset`, not the DB row — its `id` matches
  # `preset_named/1`'s row id (the DOM ids the LiveView renders), so tests can compute an
  # expected total from the snapshot and still address the same column by that id.
  defp valuation_preset_named(snapshot, name),
    do: Enum.find(snapshot.headcount_presets, &(&1.name == name))

  defp total_text(snapshot, preset, target) do
    counts = Headcount.evaluate(snapshot, preset, target)
    "#{counts.adults} + #{counts.children} = #{counts.total}"
  end

  # -- nav -------------------------------------------------------------------------------

  describe "nav" do
    test "has a Headcount entry right after Invitations, linking to /headcount", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/headcount")

      html = render(view)
      {invitations_pos, _} = :binary.match(html, "id=\"nav-invitations\"")
      {headcount_pos, _} = :binary.match(html, "id=\"nav-headcount\"")
      {events_pos, _} = :binary.match(html, "id=\"nav-events\"")

      assert invitations_pos < headcount_pos
      assert headcount_pos < events_pos
      assert has_element?(view, "#nav-headcount a[href='/headcount']", "Headcount")
    end
  end

  # -- empty state -------------------------------------------------------------------------

  describe "empty state (no events)" do
    test "shows 'Add an event first' with a link to /events", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/headcount")

      assert has_element?(view, "#headcount-no-events")
      assert has_element?(view, "#headcount-no-events a[href='/events']")
      refute has_element?(view, "#headcount-overview")
    end
  end

  # -- H1 (required test) -------------------------------------------------------------------

  describe "H1 through the UI (docs/07-normative-examples.md)" do
    setup %{scope: scope} do
      {:ok, dinner} = Events.create_event(scope, %{"name" => "Dinner"})
      h1 = NormativeGuests.h1!(scope, dinner)
      %{dinner: dinner, h1: h1}
    end

    test "the Dinner row's cells under Minimum/Likely/Maximum show 7 / 9 / 10, matching Headcount.evaluate/3",
         %{conn: conn, dinner: dinner} do
      {:ok, view, _html} = live(conn, ~p"/headcount")
      snapshot = Snapshot.load(Repo)

      for name <- ["Minimum", "Likely", "Maximum"] do
        preset = preset_named(name)
        expected = total_text(snapshot, valuation_preset_named(snapshot, name), dinner)

        assert has_element?(
                 view,
                 "#headcount-cell-#{dinner.id}-#{preset.id} summary",
                 expected
               )
      end

      minimum = preset_named("Minimum")
      likely = preset_named("Likely")
      maximum = preset_named("Maximum")

      assert has_element?(view, "#headcount-cell-#{dinner.id}-#{minimum.id} summary", "6 + 1 = 7")
      assert has_element?(view, "#headcount-cell-#{dinner.id}-#{likely.id} summary", "7 + 2 = 9")

      assert has_element?(
               view,
               "#headcount-cell-#{dinner.id}-#{maximum.id} summary",
               "7 + 3 = 10"
             )
    end

    test "the Likely cell's formula names the preset and has the accepted/invited steps", %{
      conn: conn,
      dinner: dinner
    } do
      {:ok, view, _html} = live(conn, ~p"/headcount")
      likely = preset_named("Likely")

      formula_id = "headcount-cell-#{dinner.id}-#{likely.id}-formula"
      assert has_element?(view, "##{formula_id}-total", "9")

      steps_html = view |> element("##{formula_id}-steps") |> render()
      assert steps_html =~ "Likely"
      assert steps_html =~ "Accepted"
      assert steps_html =~ "Invited"
      refute steps_html =~ "Planned"
    end

    test "the Likely cell's names contain the counted persons but not the planned uncertain one",
         %{conn: conn, dinner: dinner, h1: h1} do
      {:ok, view, _html} = live(conn, ~p"/headcount")
      likely = preset_named("Likely")

      names_html =
        view |> element("#headcount-cell-#{dinner.id}-#{likely.id}-names") |> render()

      [accepted_person | _] = h1.accepted
      [planned_uncertain_person] = h1.planned_uncertain

      assert names_html =~ WeddingPlanner.Guests.Person.display_name(accepted_person)
      refute names_html =~ WeddingPlanner.Guests.Person.display_name(planned_uncertain_person)
    end
  end

  # -- All events (required test) -----------------------------------------------------------

  describe "the All events row (HC-03)" do
    test "a person counted for both events is counted once, not twice", %{
      conn: conn,
      scope: scope
    } do
      {:ok, ceremony} = Events.create_event(scope, %{"name" => "Ceremony"})
      {:ok, dinner} = Events.create_event(scope, %{"name" => "Dinner"})

      {:ok, person} =
        Guests.create_person(scope, %{"first_name" => "Anna", "last_name" => "Peeters"})

      {:ok, _} = Invitations.set_invitation_status(scope, person, ceremony, :accepted)
      {:ok, _} = Invitations.set_invitation_status(scope, person, dinner, :accepted)

      {:ok, view, _html} = live(conn, ~p"/headcount")
      snapshot = Snapshot.load(Repo)
      maximum = preset_named("Maximum")

      expected = total_text(snapshot, valuation_preset_named(snapshot, "Maximum"), :all_events)
      assert expected == "1 + 0 = 1"

      assert has_element?(view, "#headcount-cell-all-#{maximum.id} summary", expected)
    end
  end

  # -- ad hoc filter (required test) --------------------------------------------------------

  describe "ad hoc filter (HC-07)" do
    setup %{scope: scope} do
      {:ok, dinner} = Events.create_event(scope, %{"name" => "Dinner"})
      h1 = NormativeGuests.h1!(scope, dinner)
      %{dinner: dinner, h1: h1}
    end

    test "checking want tier 'maybe' adds the ad hoc column with the filtered counts", %{
      conn: conn,
      scope: scope,
      dinner: dinner
    } do
      # A person only countable through the want-tier criterion (planned/certain, want maybe).
      {:ok, extra} =
        Guests.create_person(scope, %{
          "first_name" => "Maybe",
          "last_name" => "Guest",
          "want_tier" => "maybe",
          "certainty" => "certain"
        })

      {:ok, _} = Invitations.set_invitation_status(scope, extra, dinner, :planned)

      {:ok, view, _html} = live(conn, ~p"/headcount")

      refute has_element?(view, "#headcount-col-adhoc")

      view
      |> form("#adhoc-filter-form", %{"adhoc" => %{"want_tiers" => ["maybe"]}})
      |> render_change()

      assert has_element?(view, "#headcount-col-adhoc", "Ad hoc filter")

      snapshot = Snapshot.load(Repo)

      adhoc = %WeddingPlanner.Valuation.Preset{
        id: nil,
        name: "Ad hoc filter",
        want_tiers: MapSet.new([:maybe])
      }

      expected = total_text(snapshot, adhoc, dinner)
      assert has_element?(view, "#headcount-cell-#{dinner.id}-adhoc summary", expected)
    end

    test "'Clear' removes the ad hoc column", %{conn: conn, dinner: dinner} do
      {:ok, view, _html} = live(conn, ~p"/headcount")

      view
      |> form("#adhoc-filter-form", %{"adhoc" => %{"want_tiers" => ["maybe"]}})
      |> render_change()

      assert has_element?(view, "#headcount-col-adhoc")
      assert has_element?(view, "#headcount-cell-#{dinner.id}-adhoc")

      view |> element("#adhoc-filter-clear") |> render_click()

      refute has_element?(view, "#headcount-col-adhoc")
    end

    test "'Save as preset' with a new name creates a preset row and a normal column appears",
         %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/headcount")

      view
      |> form("#adhoc-filter-form", %{"adhoc" => %{"want_tiers" => ["maybe"]}})
      |> render_change()

      assert has_element?(view, "#adhoc-save-form")

      view
      |> form("#adhoc-save-form", %{"preset_save" => %{"name" => "Maybes only"}})
      |> render_submit()

      saved = preset_named("Maybes only")
      assert saved
      assert saved.want_tiers == [:maybe]

      refute has_element?(view, "#headcount-col-adhoc")
      assert has_element?(view, "#headcount-col-#{saved.id}", "Maybes only")
    end

    test "a duplicate name shows the changeset error and creates nothing", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/headcount")

      view
      |> form("#adhoc-filter-form", %{"adhoc" => %{"want_tiers" => ["maybe"]}})
      |> render_change()

      before_count = length(Presets.list_presets())

      html =
        view
        |> form("#adhoc-save-form", %{"preset_save" => %{"name" => "likely"}})
        |> render_submit()

      assert html =~ "is already used by"
      assert length(Presets.list_presets()) == before_count
      # The ad hoc column is not cleared on a failed save.
      assert has_element?(view, "#headcount-col-adhoc")
    end

    test "the five checkbox groups each carry a hidden empty-value input (unchecking the last box submits an empty list)",
         %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/headcount")

      for field <- ~w(invitation_statuses certainties want_tiers age_categories group_ids) do
        assert has_element?(view, "input[type=hidden][name='adhoc[#{field}][]'][value='']"),
               "expected a hidden empty-value input for '#{field}'"
      end
    end
  end

  # -- live updates (required test) ---------------------------------------------------------

  describe "live updates (XC-01)" do
    test "an invitation status change from another process updates the Dinner totals without reload",
         %{conn: conn, scope: scope} do
      {:ok, dinner} = Events.create_event(scope, %{"name" => "Dinner"})

      {:ok, person} =
        Guests.create_person(scope, %{
          "first_name" => "Anna",
          "last_name" => "Peeters",
          "certainty" => "certain"
        })

      {:ok, view, _html} = live(conn, ~p"/headcount")
      minimum = preset_named("Minimum")

      assert has_element?(view, "#headcount-cell-#{dinner.id}-#{minimum.id} summary", "0 + 0 = 0")

      {:ok, _} = Invitations.set_invitation_status(scope, person, dinner, :accepted)
      _ = :sys.get_state(view.pid)

      assert has_element?(view, "#headcount-cell-#{dinner.id}-#{minimum.id} summary", "1 + 0 = 1")
    end

    test "Presets.create_preset/2 adds a column live", %{conn: conn, scope: scope} do
      {:ok, _dinner} = Events.create_event(scope, %{"name" => "Dinner"})
      {:ok, view, _html} = live(conn, ~p"/headcount")

      refute has_element?(view, "#headcount-col-9999999")

      {:ok, preset} = Presets.create_preset(scope, %{"name" => "Live added"})
      _ = :sys.get_state(view.pid)

      assert has_element?(view, "#headcount-col-#{preset.id}", "Live added")
    end
  end

  defp insert_user!(display_name) do
    %User{} |> User.changeset(%{display_name: display_name}) |> Repo.insert!()
  end
end
