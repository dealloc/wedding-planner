defmodule WeddingPlannerWeb.Live.WhatIfLiveTest do
  @moduledoc """
  `/what-if` (task 89; `BUD-20`, `BUD-21`, `INVT-04`, `HC-08`, `HC-10`, `NFR-32`,
  `XC-01`, `DR-80`, `DR-82`, `DR-83`). Real database rows throughout
  (`WeddingPlanner.NormativeGuests`, `WeddingPlanner.NormativeOfferRows` — the
  `WeddingPlannerWeb.Live.BudgetLiveTest` precedent), so a headcount-dependent figure
  genuinely varies with the preset — the production path, no `headcount:` test seam.

  `async: false`: reads stored `WeddingPlanner.Presets.HeadcountPreset` rows by name.
  """
  use WeddingPlannerWeb.ConnCase, async: false

  import Phoenix.LiveViewTest
  import WeddingPlanner.OfferFixtures

  alias WeddingPlanner.Guests
  alias WeddingPlanner.Invitations
  alias WeddingPlanner.Invitations.Invitation
  alias WeddingPlanner.NormativeExamples, as: NE
  alias WeddingPlanner.NormativeGuests
  alias WeddingPlanner.NormativeOfferRows, as: Rows
  alias WeddingPlanner.Offers
  alias WeddingPlanner.Presets.HeadcountPreset
  alias WeddingPlanner.Repo

  setup %{conn: conn} do
    scope = scope_fixture()
    %{conn: log_in_user(conn, scope.user), scope: scope}
  end

  # -- helpers (the `BudgetLiveTest` precedent) ---------------------------------------------

  defp preset_named(name), do: Repo.get_by!(HeadcountPreset, name: name)

  defp confirmed_venue_a(scope) do
    dinner = Rows.dinner!(scope)
    guests = NormativeGuests.shared_dinner!(scope, dinner)
    {venue, services} = Rows.category!(scope, NE.venue_category())
    %{offer: offer} = Rows.offer!(scope, :venue_a, venue, services, dinner)
    {:ok, confirmed} = Offers.confirm_offer(scope, offer)
    %{category: venue, offer: confirmed, dinner: dinner, guests: guests}
  end

  defp uninvited!(scope), do: NormativeGuests.uninvited!(scope, :maybe)

  defp set_cell(view, person_id, event_id, status) do
    view
    |> element("#what-if-cell-#{person_id}-#{event_id}-form")
    |> render_change(%{"status" => status})
  end

  # -- 5. entry / selection (?people=, ?group=, +1s, garbage) -------------------------------

  describe "selection from the URL (DR-82)" do
    test "?people=<a>,<b> renders both cards; garbage ids are ignored", %{
      conn: conn,
      scope: scope
    } do
      a = uninvited!(scope)
      b = uninvited!(scope)

      people = "#{a.id},#{b.id},999999,notanumber"
      {:ok, view, _html} = live(conn, ~p"/what-if?people=#{people}")

      assert has_element?(view, "#what-if-person-#{a.id}")
      assert has_element?(view, "#what-if-person-#{b.id}")
      refute has_element?(view, "#what-if-person-999999")
    end

    test "a +1 id in ?people= selects its host instead", %{conn: conn, scope: scope} do
      host = uninvited!(scope)
      {:ok, plus_one} = Guests.add_plus_one(scope, host, %{plus_one_status: :confirmed})

      {:ok, view, _html} = live(conn, ~p"/what-if?people=#{plus_one.id}")

      assert has_element?(view, "#what-if-person-#{host.id}")
      refute has_element?(view, "#what-if-person-#{plus_one.id}")
      assert has_element?(view, "#what-if-person-#{host.id}-plus-one-#{plus_one.id}")
    end

    test "?group=<id> adds the group's non-+1 members", %{conn: conn, scope: scope} do
      {:ok, group} = Guests.create_group(scope, %{name: "Group W13", type_label: "circle"})

      {:ok, [m1, m2]} =
        Guests.bulk_create_persons(
          scope,
          [%{first_name: "M1", last_name: "One"}, %{first_name: "M2", last_name: "Two"}],
          %{group_id: group.id}
        )

      {:ok, view, _html} = live(conn, ~p"/what-if?group=#{group.id}")

      assert has_element?(view, "#what-if-person-#{m1.id}")
      assert has_element?(view, "#what-if-person-#{m2.id}")
    end
  end

  # -- 6. no write before Apply (BUD-20, FP-89a) ---------------------------------------------

  describe "changing a cell (BUD-20)" do
    test "updates #what-if-summary and the Dinner headcount row; writes nothing (fail-proof: write the invitation on each cell change)",
         %{conn: conn, scope: scope} do
      %{dinner: dinner} = confirmed_venue_a(scope)
      person = uninvited!(scope)
      count_before = Repo.aggregate(Invitation, :count)

      {:ok, view, _html} = live(conn, ~p"/what-if?people=#{person.id}")
      assert render(view) =~ "No changes yet"

      before_headcount = view |> element("#what-if-headcount-#{dinner.id}") |> render()

      set_cell(view, person.id, dinner.id, "invited")
      render_async(view)

      assert render(view) =~ "1 change for 1 person"
      after_headcount = view |> element("#what-if-headcount-#{dinner.id}") |> render()
      refute before_headcount == after_headcount

      assert Repo.aggregate(Invitation, :count) == count_before
      assert Repo.get_by(Invitation, person_id: person.id, event_id: dinner.id) == nil
    end
  end

  # -- 7. Set for everyone here --------------------------------------------------------------

  describe "Set for everyone here" do
    test "sets every selected person's cell for that event", %{conn: conn, scope: scope} do
      %{dinner: dinner} = confirmed_venue_a(scope)
      a = uninvited!(scope)
      b = uninvited!(scope)

      people = "#{a.id},#{b.id}"
      {:ok, view, _html} = live(conn, ~p"/what-if?people=#{people}")

      view
      |> element("#what-if-set-all")
      |> render_submit(%{"event_id" => to_string(dinner.id), "status" => "invited"})

      render_async(view)

      assert has_element?(
               view,
               "#what-if-cell-#{a.id}-#{dinner.id} option[value=invited][selected]"
             )

      assert has_element?(
               view,
               "#what-if-cell-#{b.id}-#{dinner.id} option[value=invited][selected]"
             )

      assert render(view) =~ "2 changes for 2 people"
    end
  end

  # -- 8. Apply (DR-83, FP-89d) ---------------------------------------------------------------

  describe "Apply (DR-83)" do
    test "opens the confirmation; Cancel writes nothing; Confirm writes, flashes, and clears the draft (fail-proof: call apply_what_if/2 directly from #what-if-apply)",
         %{conn: conn, scope: scope} do
      %{dinner: dinner} = confirmed_venue_a(scope)
      person = uninvited!(scope)

      {:ok, view, _html} = live(conn, ~p"/what-if?people=#{person.id}")
      set_cell(view, person.id, dinner.id, "invited")
      render_async(view)

      assert has_element?(view, "#what-if-apply:not([disabled])")

      view |> element("#what-if-apply") |> render_click()
      assert has_element?(view, "#what-if-apply-confirm")

      confirm_html = view |> element("#what-if-apply-confirm") |> render()
      assert confirm_html =~ "Dinner: Not invited → Invited"

      view |> element("#what-if-apply-cancel") |> render_click()
      refute has_element?(view, "#what-if-apply-confirm")
      assert Repo.get_by(Invitation, person_id: person.id, event_id: dinner.id) == nil

      view |> element("#what-if-apply") |> render_click()
      view |> element("#what-if-apply-confirmed") |> render_click()
      render_async(view)

      assert Repo.get_by(Invitation, person_id: person.id, event_id: dinner.id).status == :invited
      assert render(view) =~ "Applied 1 invitation change"
      refute has_element?(view, "#what-if-apply-confirm")
      assert render(view) =~ "No changes yet"
    end
  end

  # -- 9. live: another change; deleting a selected person (XC-01, FP-89c, FP-89e) -----------

  describe "live updates (XC-01)" do
    test "a change from elsewhere updates the preview's 'before'; the draft survives (fail-proof: reset the draft on a live message)",
         %{conn: conn, scope: scope} do
      %{dinner: dinner} = confirmed_venue_a(scope)
      a = uninvited!(scope)
      elsewhere = uninvited!(scope)

      {:ok, view, _html} = live(conn, ~p"/what-if?people=#{a.id}")
      set_cell(view, a.id, dinner.id, "invited")
      render_async(view)

      before_headcount = view |> element("#what-if-headcount-#{dinner.id}") |> render()

      {:ok, _} = Invitations.set_invitation_status(scope, elsewhere, dinner, :accepted)
      # Synchronizes on the LiveView process having handled the `:invitation` broadcast
      # (and so having started its own `start_async/3` recompute) before `render_async/1`
      # waits for it — otherwise this is a race: `render_async/1` returns immediately
      # when there is no async task in flight yet, letting `after_headcount` be captured
      # before the live update lands (AGENTS.md: sync via `:sys.get_state/1`, never sleep).
      _ = :sys.get_state(view.pid)
      render_async(view)

      after_headcount = view |> element("#what-if-headcount-#{dinner.id}") |> render()
      refute before_headcount == after_headcount
      # the draft survives — still 1 change for 1 person
      assert render(view) =~ "1 change for 1 person"
    end

    test "deleting a selected person removes their card, no crash (fail-proof: drop the :invitation subscription — see the sibling test above)",
         %{conn: conn, scope: scope} do
      a = uninvited!(scope)
      doomed = uninvited!(scope)

      people = "#{a.id},#{doomed.id}"
      {:ok, view, _html} = live(conn, ~p"/what-if?people=#{people}")
      assert has_element?(view, "#what-if-person-#{doomed.id}")

      {:ok, _} = Guests.delete_person(scope, doomed)
      _ = :sys.get_state(view.pid)
      render_async(view)

      refute has_element?(view, "#what-if-person-#{doomed.id}")
      assert has_element?(view, "#what-if-person-#{a.id}")
      assert Process.alive?(view.pid)
    end
  end

  # -- 10. preset selector drives formulas, not the three values (HC-10) ---------------------

  describe "the preset selector (HC-10)" do
    test "changing it updates the formulas' preset step, not the three role values", %{
      conn: conn,
      scope: scope
    } do
      %{dinner: dinner} = confirmed_venue_a(scope)
      person = uninvited!(scope)
      minimum = preset_named("Minimum")

      {:ok, view, _html} = live(conn, ~p"/what-if?people=#{person.id}")
      set_cell(view, person.id, dinner.id, "invited")
      render_async(view)

      before_values =
        view |> element("#what-if-headcount-#{dinner.id}-values") |> render()

      view
      |> element("#what-if-preset")
      |> render_change(%{"what-if-preset-selector-preset" => to_string(minimum.id)})

      render_async(view)

      after_values = view |> element("#what-if-headcount-#{dinner.id}-values") |> render()
      assert before_values == after_values

      assert has_element?(view, "#what-if-preset-selector-option-#{minimum.id}[checked]")
    end
  end

  # -- 11. disabled Apply with no changes -----------------------------------------------------

  describe "Apply disabled with no changes" do
    test "#what-if-apply[disabled] renders with no changes", %{conn: conn, scope: scope} do
      person = uninvited!(scope)
      {:ok, view, _html} = live(conn, ~p"/what-if?people=#{person.id}")

      assert has_element?(view, "#what-if-apply[disabled]")
    end
  end

  # -- 12. no rendered "false" -----------------------------------------------------------------

  describe "no rendered boolean literal" do
    test "no bare \"false\" text anywhere on the page", %{conn: conn, scope: scope} do
      %{dinner: dinner} = confirmed_venue_a(scope)
      person = uninvited!(scope)

      {:ok, view, _html} = live(conn, ~p"/what-if?people=#{person.id}")
      set_cell(view, person.id, dinner.id, "invited")
      render_async(view)

      html = render(view)
      refute html =~ ~r/>\s*false\s*</
    end
  end

  # -- loading (orchestrator amendment, loading state & latency) ------------------------------

  describe "loading state (the async recompute)" do
    test "a cell change's own reply carries JS.push's own :loading target (fail-proof: drop :loading)",
         %{conn: conn, scope: scope} do
      %{dinner: dinner} = confirmed_venue_a(scope)
      person = uninvited!(scope)

      {:ok, view, _html} = live(conn, ~p"/what-if?people=#{person.id}")

      loading_json =
        ~s(loading&quot;:&quot;#what-if-preview, #what-if-updating&quot;)

      form_html = view |> element("#what-if-cell-#{person.id}-#{dinner.id}-form") |> render()
      assert form_html =~ loading_json

      assert has_element?(view, "#what-if-updating.hidden.phx-change-loading\\:flex")
    end
  end
end
