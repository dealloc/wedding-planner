defmodule WeddingPlannerWeb.Live.ReloadOnImportHookTest do
  @moduledoc """
  `WeddingPlannerWeb.Live.ReloadOnImportHook` (task 99; a data-transfer feature the user
  requested, not yet in `docs/` — `.claude/plans/w15-transfer-plan.md` `DR-93`, `DR-95`;
  `docs/04-cross-cutting.md` `XC-01`, `XC-02`; `docs/06-decisions-and-defaults.md`
  `DR-21`): the central `on_mount` hook attached to every `live_session :authenticated`
  LiveView, that reloads every open screen after a data import — except the screen that
  ran it.

  `async: false`: several tests broadcast on `WeddingPlanner.Realtime`'s shared PubSub
  and read across two connected views in the same test (the `OfferLiveConfirmationTest`
  precedent).
  """
  use WeddingPlannerWeb.ConnCase, async: false

  import Phoenix.LiveViewTest
  import WeddingPlanner.OfferFixtures, only: [scope_fixture: 1]

  alias WeddingPlanner.Events
  alias WeddingPlanner.Realtime
  alias WeddingPlannerWeb.Live.ReloadOnImportHook
  alias WeddingPlannerWeb.Router

  setup %{conn: conn} do
    scope = scope_fixture("Wannes")
    %{conn: log_in_user(conn, scope.user), scope: scope}
  end

  # -- helpers -----------------------------------------------------------------------------

  # The exact §5 broadcast contract task 100 will send (restated in this task's brief and
  # the plan): `{:created, %{origin:, exported_at:, source_host:}}` on `:data_import`.
  defp broadcast_import(origin) do
    Realtime.broadcast_change(
      :data_import,
      {:created,
       %{
         origin: origin,
         exported_at: DateTime.utc_now() |> DateTime.truncate(:second),
         source_host: "localhost:4000"
       }}
    )
  end

  # -- FP-99a: a second screen reloads, keeping its own path + query -----------------------

  describe "FP-99a: other open screens reload to their own current URL" do
    test "an import with no origin push_navigates every other screen back to its own path",
         %{conn: conn} do
      {:ok, people_view, _html} = live(conn, ~p"/people")
      {:ok, tasks_view, _html} = live(conn, ~p"/tasks?filter=overdue")

      broadcast_import(nil)

      assert_redirect(people_view, "/people")
      assert_redirect(tasks_view, "/tasks?filter=overdue")
    end

    test "a LiveView that defines no handle_params/3 of its own still reloads to /settings",
         %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/settings")

      refute function_exported?(WeddingPlannerWeb.Live.SettingsLive, :handle_params, 3)

      broadcast_import(nil)

      assert_redirect(view, "/settings")
    end
  end

  # -- FP-99b: the importing screen is left alone ------------------------------------------

  describe "FP-99b: the importing screen (origin == self()) is left alone" do
    test "no redirect, and the view keeps rendering", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/people")

      broadcast_import(view.pid)

      # Synchronize with the view's mailbox before checking: it must have already handled
      # (and swallowed) the message by the time render/1 returns.
      html = render(view)

      assert :ok = refute_redirected(view)
      assert html =~ "People"
      assert has_element?(view, "#nav-people a", "People")
    end
  end

  # -- FP-99c: every other message still reaches the LiveView's own handle_info/2 ----------

  describe "FP-99c: every other message still reaches the LiveView unchanged" do
    test "an ordinary Realtime broadcast on another topic still updates the view",
         %{conn: conn, scope: scope} do
      {:ok, view, _html} = live(conn, ~p"/events")

      {:ok, event} =
        Events.create_event(scope, %{
          "couple_attends" => false,
          "name" => "Reception",
          "date" => "2028-05-14"
        })

      assert has_element?(view, "#events-#{event.id}")
    end

    test "an unexpected :data_import payload shape halts safely, without crashing the view",
         %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/events")

      send(view.pid, {Realtime, :data_import, {:updated, %{origin: nil}}})
      send(view.pid, {Realtime, :data_import, :not_even_a_tuple_payload})

      assert render(view) =~ "Events"
      refute_redirected(view)
    end
  end

  # -- FP-99d: every authenticated live route runs the hook, :public gets none ------------

  describe "FP-99d: route coverage" do
    test "every :authenticated live_session route carries the hook; :public carries none" do
      live_routes =
        for route <- Router.__routes__(), match?(%{phoenix_live_view: _}, route.metadata) do
          route
        end

      # Sanity: this test would trivially pass on an empty list.
      assert length(live_routes) > 10

      for route <- live_routes do
        %{phoenix_live_view: {_live_view, _action, _opts, live_session}} = route.metadata
        on_mount_ids = for %{id: id} <- live_session.extra[:on_mount] || [], do: id

        case live_session.name do
          :authenticated ->
            assert {ReloadOnImportHook, :default} in on_mount_ids,
                   "expected #{route.path} (live_session :authenticated) to run " <>
                     "ReloadOnImportHook, got on_mount: #{inspect(on_mount_ids)}"

          :public ->
            refute {ReloadOnImportHook, :default} in on_mount_ids,
                   "expected #{route.path} (live_session :public) NOT to run " <>
                     "ReloadOnImportHook, got on_mount: #{inspect(on_mount_ids)}"

          other ->
            flunk(
              "unexpected live_session #{inspect(other)} for #{route.path} — " <>
                "this test only knows about :authenticated and :public, update it"
            )
        end
      end
    end
  end

  # -- Disconnected (static) render ---------------------------------------------------------

  describe "disconnected render" do
    test "a plain GET does not subscribe or crash", %{conn: conn} do
      conn = get(conn, ~p"/people")

      assert html_response(conn, 200)
    end
  end
end
