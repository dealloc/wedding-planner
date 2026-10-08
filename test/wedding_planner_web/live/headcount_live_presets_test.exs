defmodule WeddingPlannerWeb.Live.HeadcountLivePresetsTest do
  @moduledoc """
  `/headcount`'s preset management section (`#presets-section`, task 62;
  `docs/modules/headcount.md` HC-06, HC-07; `docs/04-cross-cutting.md` XC-10, XC-11,
  XC-40; `DR-53`, `DR-55`, `DR-54` **revised**).

  **`DR-54` revised (binding orchestrator ruling, 2026-09-24):** the three seeded
  defaults (`role` in `:minimum`/`:likely`/`:maximum`) are locked — no rename, no
  criteria edit, no role change (there is no role picker at all any more), no delete.
  Reordering is unaffected (list order is presentation, not identity) and stays
  available to every preset, defaults included. `WeddingPlanner.PresetsTest` covers the
  context-level enforcement (`{:error, :default_preset_locked}`); this file covers the
  screen: what a default's row looks like (no Edit/Delete affordance), that the guard
  holds even against a raw event, and the full CRUD surface for a **custom** preset
  (create, rename, edit criteria including a group, delete with confirmation, history).

  Real database rows throughout (`WeddingPlanner.NormativeGuests`-style direct context
  calls) → `WeddingPlanner.Valuation.Snapshot.load/1` → the production engine, mirroring
  `WeddingPlannerWeb.Live.HeadcountLiveTest`'s own discipline.
  """
  use WeddingPlannerWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias WeddingPlanner.Accounts.Scope
  alias WeddingPlanner.Accounts.User
  alias WeddingPlanner.Events
  alias WeddingPlanner.Guests
  alias WeddingPlanner.Invitations
  alias WeddingPlanner.Log.Query
  alias WeddingPlanner.Presets
  alias WeddingPlanner.Repo
  alias WeddingPlanner.Valuation.Headcount
  alias WeddingPlanner.Valuation.Snapshot

  setup %{conn: conn} do
    user = insert_user!("Wannes")
    %{conn: log_in_user(conn, user), user: user, scope: Scope.for_user(user)}
  end

  defp preset_named(name), do: Enum.find(Presets.list_presets(), &(&1.name == name))

  defp valuation_preset_named(snapshot, name),
    do: Enum.find(snapshot.headcount_presets, &(&1.name == name))

  defp total_text(snapshot, preset, target) do
    counts = Headcount.evaluate(snapshot, preset, target)
    "#{counts.adults} + #{counts.children} = #{counts.total}"
  end

  # -- locked defaults (DR-54 revised) -------------------------------------------------------

  describe "the three defaults are locked (DR-54 revised)" do
    test "each default shows the 'Default (locked)' badge and no Edit/Delete, but keeps its reorder buttons",
         %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/headcount")

      for name <- ["Minimum", "Likely", "Maximum"] do
        preset = preset_named(name)

        assert has_element?(view, "#preset-#{preset.id}-role", "Default (locked)")
        refute has_element?(view, "#preset-edit-#{preset.id}")
        refute has_element?(view, "#preset-delete-#{preset.id}")
        assert has_element?(view, "#preset-up-#{preset.id}")
        assert has_element?(view, "#preset-down-#{preset.id}")
      end
    end

    test "a custom preset shows no 'Default (locked)' badge, and does show Edit/Delete", %{
      conn: conn,
      scope: scope
    } do
      {:ok, custom} = Presets.create_preset(scope, %{"name" => "Custom"})
      {:ok, view, _html} = live(conn, ~p"/headcount")

      refute has_element?(view, "#preset-#{custom.id}-role")
      assert has_element?(view, "#preset-edit-#{custom.id}")
      assert has_element?(view, "#preset-delete-#{custom.id}")
    end

    test "edit_preset/confirm_delete_preset ignore a locked preset's id even via a raw event (defensive)",
         %{conn: conn} do
      minimum = preset_named("Minimum")
      {:ok, view, _html} = live(conn, ~p"/headcount")

      render_click(view, "edit_preset", %{"id" => to_string(minimum.id)})
      refute has_element?(view, "#preset-form")

      render_click(view, "confirm_delete_preset", %{"id" => to_string(minimum.id)})
      refute has_element?(view, "#preset-delete-confirm-#{minimum.id}")

      assert Presets.get_preset!(minimum.id).name == "Minimum"
    end

    test "reordering 'Minimum' down swaps it with its neighbour, in both the section and the overview columns",
         %{conn: conn, scope: scope} do
      {:ok, _dinner} =
        Events.create_event(scope, %{"couple_attends" => false, "name" => "Dinner"})

      minimum = preset_named("Minimum")
      likely = preset_named("Likely")

      {:ok, view, _html} = live(conn, ~p"/headcount")

      html = render(view)
      {min_col, _} = :binary.match(html, "headcount-col-#{minimum.id}")
      {likely_col, _} = :binary.match(html, "headcount-col-#{likely.id}")
      assert min_col < likely_col

      {min_row, _} = :binary.match(html, "id=\"preset-#{minimum.id}\"")
      {likely_row, _} = :binary.match(html, "id=\"preset-#{likely.id}\"")
      assert min_row < likely_row

      view |> element("#preset-down-#{minimum.id}") |> render_click()

      reloaded = Presets.list_presets()

      assert Enum.find_index(reloaded, &(&1.id == minimum.id)) >
               Enum.find_index(reloaded, &(&1.id == likely.id))

      html2 = render(view)
      {min_col2, _} = :binary.match(html2, "headcount-col-#{minimum.id}")
      {likely_col2, _} = :binary.match(html2, "headcount-col-#{likely.id}")
      assert likely_col2 < min_col2

      {min_row2, _} = :binary.match(html2, "id=\"preset-#{minimum.id}\"")
      {likely_row2, _} = :binary.match(html2, "id=\"preset-#{likely.id}\"")
      assert likely_row2 < min_row2
    end
  end

  # -- custom preset CRUD (HC-06, HC-07) ------------------------------------------------------

  describe "custom preset CRUD" do
    test "'New preset' creates a custom preset that appears as an overview column", %{
      conn: conn,
      scope: scope
    } do
      {:ok, _dinner} =
        Events.create_event(scope, %{"couple_attends" => false, "name" => "Dinner"})

      {:ok, view, _html} = live(conn, ~p"/headcount")

      refute has_element?(view, "#preset-form")
      view |> element("#preset-new") |> render_click()
      assert has_element?(view, "#preset-form")

      view
      |> form("#preset-form", %{
        "preset" => %{"name" => "Custom", "want_tiers" => ["yes"]}
      })
      |> render_submit()

      refute has_element?(view, "#preset-form")

      custom = preset_named("Custom")
      assert custom
      assert custom.want_tiers == [:yes]
      assert has_element?(view, "#headcount-col-#{custom.id}", "Custom")
    end

    test "renaming a custom preset live-updates the overview column header (needs the :headcount_preset subscription)",
         %{conn: conn, scope: scope} do
      {:ok, _dinner} =
        Events.create_event(scope, %{"couple_attends" => false, "name" => "Dinner"})

      {:ok, custom} = Presets.create_preset(scope, %{"name" => "Custom"})

      {:ok, view, _html} = live(conn, ~p"/headcount")
      assert has_element?(view, "#headcount-col-#{custom.id}", "Custom")

      # Renamed directly through the context, from the *test* process — never through
      # this LiveView's own `handle_event/3` — so the column can only follow via the
      # `:headcount_preset` broadcast this view subscribes to on mount.
      {:ok, _} = Presets.update_preset(scope, custom, %{"name" => "Renamed"})
      _ = :sys.get_state(view.pid)

      assert has_element?(view, "#headcount-col-#{custom.id}", "Renamed")
      refute has_element?(view, "#headcount-col-#{custom.id}", "Custom")

      entries = Query.for_entity(:headcount_preset, custom.id)
      assert Enum.count(entries, &(&1.description =~ "changed the name")) == 1
    end

    test "editing a custom preset's criteria (adding a group) recomputes its overview column",
         %{conn: conn, scope: scope} do
      {:ok, dinner} = Events.create_event(scope, %{"couple_attends" => false, "name" => "Dinner"})
      {:ok, group} = Guests.create_group(scope, %{"name" => "Friends"})

      {:ok, anna} =
        Guests.create_person(scope, %{
          "first_name" => "Anna",
          "last_name" => "Peeters",
          "certainty" => "certain",
          "group_id" => group.id
        })

      {:ok, bert} =
        Guests.create_person(scope, %{
          "first_name" => "Bert",
          "last_name" => "Someone",
          "certainty" => "certain"
        })

      {:ok, _} = Invitations.set_invitation_status(scope, anna, dinner, :accepted)
      {:ok, _} = Invitations.set_invitation_status(scope, bert, dinner, :accepted)

      {:ok, custom} = Presets.create_preset(scope, %{"name" => "Custom"})

      {:ok, view, _html} = live(conn, ~p"/headcount")

      view |> element("#preset-edit-#{custom.id}") |> render_click()

      view
      |> form("#preset-form", %{"preset" => %{"group_ids" => [to_string(group.id)]}})
      |> render_submit()

      assert Presets.get_preset!(custom.id).group_ids == [group.id]

      snapshot = Snapshot.load(Repo)
      valuation_preset = valuation_preset_named(snapshot, "Custom")
      expected = total_text(snapshot, valuation_preset, dinner)

      assert has_element?(view, "#headcount-cell-#{dinner.id}-#{custom.id} summary", expected)
      # Only Anna (in "Friends") should be counted now — sanity that the group filter
      # actually narrowed the column, not left it unrestricted.
      assert expected == "1 + 0 = 1"
    end

    test "unchecking every certainty box (with the hidden empty-value input) stores [] (= any)",
         %{conn: conn, scope: scope} do
      {:ok, custom} =
        Presets.create_preset(scope, %{"name" => "Custom", "certainties" => ["certain"]})

      {:ok, view, _html} = live(conn, ~p"/headcount")

      view |> element("#preset-edit-#{custom.id}") |> render_click()
      assert has_element?(view, "#preset-form-certainties-certain[checked]")

      # Step 1: simulate the user unchecking "Certain" — an explicit override at the
      # `phx-change` step, exactly like a real browser's change event would (only the
      # hidden empty-value input's own "" survives the query-string round trip; a bare
      # `[]` override has no wire representation and would silently vanish).
      view
      |> form("#preset-form", %{"preset" => %{"certainties" => [""]}})
      |> render_change()

      refute has_element?(view, "#preset-form-certainties-certain[checked]")

      # Step 2: the actual save round-trips through the *real rendered form* with no
      # manual override for "certainties" at all — it only works if the hidden
      # empty-value input is still there to carry "" through when nothing is checked.
      view |> form("#preset-form") |> render_submit()

      assert Presets.get_preset!(custom.id).certainties == []
    end

    test "deleting a custom preset requires confirmation; confirming deletes it and its column disappears",
         %{conn: conn, scope: scope} do
      {:ok, _dinner} =
        Events.create_event(scope, %{"couple_attends" => false, "name" => "Dinner"})

      {:ok, custom} = Presets.create_preset(scope, %{"name" => "Custom"})

      {:ok, view, _html} = live(conn, ~p"/headcount")
      assert has_element?(view, "#headcount-col-#{custom.id}")

      view |> element("#preset-delete-#{custom.id}") |> render_click()
      assert has_element?(view, "#preset-delete-confirm-#{custom.id}")

      # Not deleted yet — the confirm button hasn't been clicked.
      assert Presets.get_preset!(custom.id)
      assert has_element?(view, "#headcount-col-#{custom.id}")

      view |> element("#preset-delete-confirm-#{custom.id}-confirm") |> render_click()

      refute Enum.any?(Presets.list_presets(), &(&1.id == custom.id))
      refute has_element?(view, "#headcount-col-#{custom.id}")
      refute has_element?(view, "#preset-#{custom.id}")
    end

    test "deleting the only custom preset leaves the three locked defaults; the page keeps working",
         %{conn: conn, scope: scope} do
      {:ok, _dinner} =
        Events.create_event(scope, %{"couple_attends" => false, "name" => "Dinner"})

      {:ok, custom} = Presets.create_preset(scope, %{"name" => "Custom"})

      {:ok, view, _html} = live(conn, ~p"/headcount")

      view |> element("#preset-delete-#{custom.id}") |> render_click()
      view |> element("#preset-delete-confirm-#{custom.id}-confirm") |> render_click()

      assert Presets.list_presets() |> Enum.map(& &1.name) |> Enum.sort() ==
               ["Likely", "Maximum", "Minimum"]

      refute has_element?(view, "#headcount-no-columns")
      minimum = preset_named("Minimum")
      assert has_element?(view, "#headcount-col-#{minimum.id}")
    end

    test "history disclosure shows the rename entry", %{conn: conn, scope: scope} do
      {:ok, custom} = Presets.create_preset(scope, %{"name" => "Custom"})
      {:ok, _} = Presets.update_preset(scope, custom, %{"name" => "Renamed"})

      {:ok, view, _html} = live(conn, ~p"/headcount")

      history_html = view |> element("#preset-#{custom.id}-history") |> render()
      assert history_html =~ "changed the name of &#39;Custom&#39;: Custom → Renamed"
    end
  end

  # -- criteria summary live updates (PER-07) -------------------------------------------------

  describe "criteria summary live updates (PER-07, DR-53)" do
    test "deleting a group via Guests.delete_group/2 drops it from the preset's summary live",
         %{conn: conn, scope: scope} do
      {:ok, group} = Guests.create_group(scope, %{"name" => "Buddies"})

      # Named so the preset's own name never contains the group's name — otherwise a
      # substring match against the whole row would pass for the wrong reason.
      {:ok, preset} =
        Presets.create_preset(scope, %{"name" => "Custom", "group_ids" => [group.id]})

      {:ok, view, _html} = live(conn, ~p"/headcount")

      assert has_element?(view, "#preset-#{preset.id}-summary", "Buddies")
      refute has_element?(view, "#preset-#{preset.id}-summary", "any group")

      {:ok, _} = Guests.delete_group(scope, group)
      _ = :sys.get_state(view.pid)

      refute has_element?(view, "#preset-#{preset.id}-summary", "Buddies")
      assert has_element?(view, "#preset-#{preset.id}-summary", "any group")
    end
  end

  # -- offer page stability under custom-preset churn (DR-54 revised) ------------------------

  describe "the offer page's default selection is unaffected by custom-preset churn" do
    test "creating, renaming and deleting custom presets never disturbs the 'Likely' default chip",
         %{conn: conn, scope: scope} do
      category = WeddingPlanner.OfferFixtures.category_fixture(scope)
      offer = WeddingPlanner.OfferFixtures.offer_fixture(scope, category)

      {:ok, offer_view, _html} = live(conn, ~p"/offers/#{offer.id}")
      likely = preset_named("Likely")
      assert has_element?(offer_view, "#offer-cost-preset-option-#{likely.id}[checked]")

      {:ok, custom} = Presets.create_preset(scope, %{"name" => "Custom"})
      {:ok, _} = Presets.update_preset(scope, custom, %{"name" => "Renamed custom"})
      {:ok, _} = Presets.delete_preset(scope, custom)

      {:ok, fresh_view, _html} = live(conn, ~p"/offers/#{offer.id}")
      assert has_element?(fresh_view, "#offer-cost-preset-option-#{likely.id}[checked]")
      assert has_element?(fresh_view, "#offer-cost-preset", "Likely")
    end
  end

  defp insert_user!(display_name) do
    %User{} |> User.changeset(%{display_name: display_name}) |> Repo.insert!()
  end
end
