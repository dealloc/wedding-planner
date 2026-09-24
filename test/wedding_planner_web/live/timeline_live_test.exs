defmodule WeddingPlannerWeb.Live.TimelineLiveTest do
  @moduledoc """
  `/timeline` (task 77; `docs/modules/tasks-and-timeline.md` **TSK-21**, **TSK-22**,
  **TSK-23**; `docs/modules/invoices-and-budget.md` **BIL-06**; `05-non-functional.md`
  **NFR-23**/**NFR-31**; `.claude/plans/roadmap.md` **DR-68**). Normative example **T5**
  (`docs/07-normative-examples.md`) is exercised end to end, tagged `@tag example: "T5"`.
  """
  use WeddingPlannerWeb.ConnCase, async: true

  import Phoenix.LiveViewTest
  import WeddingPlanner.InvoiceFixtures

  alias WeddingPlanner.Accounts.Passkey
  alias WeddingPlanner.Accounts.Scope
  alias WeddingPlanner.Accounts.User
  alias WeddingPlanner.Categories
  alias WeddingPlanner.Events
  alias WeddingPlanner.Invoices
  alias WeddingPlanner.Repo
  alias WeddingPlanner.Tasks

  setup %{conn: conn} do
    wannes = insert_user!("Wannes")
    insert_passkey!(wannes)
    scope = Scope.for_user(wannes)

    {:ok, category} = Categories.create_category(scope, %{"name" => "Venue"})

    %{conn: log_in_user(conn, wannes), scope: scope, category: category}
  end

  defp task!(scope, title, attrs \\ %{}) do
    {:ok, task} = Tasks.create_task(scope, Map.merge(%{"title" => title}, attrs))
    task
  end

  defp event!(scope, name, attrs \\ %{}) do
    {:ok, event} = Events.create_event(scope, Map.merge(%{"name" => name}, attrs))
    event
  end

  defp find(html, selector), do: html |> LazyHTML.from_fragment() |> LazyHTML.query(selector)
  defp attr(html, selector, name), do: html |> find(selector) |> LazyHTML.attribute(name)

  defp top_offset(style) do
    [_, px] = Regex.run(~r/top:\s*(-?\d+)px/, style)
    px
  end

  describe "nav (DR-60, DR-68)" do
    test "Timeline sits in the primary tier, directly after Tasks", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/timeline")

      html = render(view)

      primary_ids =
        html |> find("#nav-primary > li") |> Enum.flat_map(&LazyHTML.attribute(&1, "id"))

      assert Enum.find_index(primary_ids, &(&1 == "nav-timeline")) ==
               Enum.find_index(primary_ids, &(&1 == "nav-tasks")) + 1

      assert has_element?(view, "#nav-timeline a", "Timeline")
    end
  end

  describe "empty states" do
    test "no tasks at all links to /tasks", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/timeline")

      assert has_element?(view, "#timeline-empty")
      assert has_element?(view, "#timeline-empty a[href='/tasks']")
    end

    test "tasks exist but none are dated shows the nothing-dated message, side lane still shown",
         %{conn: conn, scope: scope} do
      task = task!(scope, "Write vows")

      {:ok, view, _html} = live(conn, ~p"/timeline")

      assert has_element?(view, "#timeline-empty", "Nothing dated yet")
      assert has_element?(view, "#timeline-side-lane")
      assert has_element?(view, "#timeline-side-#{task.id}")
    end
  end

  describe "rendering (TSK-21, TSK-22, BIL-06)" do
    test "renders points for dated tasks, the side lane for undated/unresolved tasks, event and invoice milestones (amount with NBSP), and the today marker",
         %{conn: conn, scope: scope, category: category} do
      ceremony = event!(scope, "Civil ceremony", %{"date" => "2030-06-01"})
      unset_event = event!(scope, "Honeymoon departure")

      dated =
        task!(scope, "Book venue", %{"deadline_kind" => "fixed", "deadline_date" => "2030-05-01"})

      no_deadline = task!(scope, "Write vows")

      unresolved =
        task!(scope, "Book honeymoon flights", %{
          "deadline_kind" => "relative",
          "deadline_amount" => "8",
          "deadline_unit" => "weeks",
          "deadline_direction" => "before",
          "deadline_event_id" => unset_event.id
        })

      invoice =
        invoice_fixture(scope, category, %{"due_date" => ~D[2030-03-01]}, %{
          "amount_input" => "1500"
        })

      {:ok, view, _html} = live(conn, ~p"/timeline")

      assert has_element?(view, "#timeline-point-#{dated.id}", "Book venue")
      assert has_element?(view, "#timeline-side-#{no_deadline.id}", "Write vows")
      assert has_element?(view, "#timeline-side-#{unresolved.id}", "Book honeymoon flights")
      assert has_element?(view, "#timeline-milestone-event-#{ceremony.id}", "Civil ceremony")
      assert has_element?(view, "#timeline-milestone-invoice-#{invoice.id}")
      assert render(view) =~ "€ 1.500,00"
      assert has_element?(view, "#timeline-today")
    end
  end

  describe "milestone and cross-page list links navigate, not patch" do
    test "clicking an event milestone navigates to its edit page", %{conn: conn, scope: scope} do
      task!(scope, "Book venue", %{"deadline_kind" => "fixed", "deadline_date" => "2030-05-01"})
      ceremony = event!(scope, "Civil ceremony", %{"date" => "2030-06-01"})

      {:ok, view, _html} = live(conn, ~p"/timeline")

      assert {:error, {:live_redirect, %{to: to}}} =
               view |> element("#timeline-milestone-event-#{ceremony.id}") |> render_click()

      assert to == "/events/#{ceremony.id}/edit"
    end

    test "clicking an invoice milestone in the list navigates to the invoice page", %{
      conn: conn,
      scope: scope,
      category: category
    } do
      task!(scope, "Book venue", %{"deadline_kind" => "fixed", "deadline_date" => "2030-04-01"})

      invoice =
        invoice_fixture(scope, category, %{"due_date" => ~D[2030-03-01]}, %{
          "amount_input" => "1500"
        })

      {:ok, view, _html} = live(conn, ~p"/timeline")

      assert {:error, {:live_redirect, %{to: to}}} =
               view |> element("#timeline-list-invoice-#{invoice.id}") |> render_click()

      assert to == "/invoices/#{invoice.id}"
    end
  end

  describe "milestone label collision avoidance (coordinator feedback, DR-68)" do
    test "two milestones on the same date land in distinct rows, each still its own clickable link",
         %{conn: conn, scope: scope} do
      task!(scope, "Book venue", %{"deadline_kind" => "fixed", "deadline_date" => "2030-04-01"})
      civil = event!(scope, "Civil ceremony", %{"date" => "2030-06-01"})
      church = event!(scope, "Church ceremony", %{"date" => "2030-06-01"})

      {:ok, view, _html} = live(conn, ~p"/timeline")

      assert has_element?(view, "#timeline-milestone-event-#{civil.id}", "Civil ceremony")
      assert has_element?(view, "#timeline-milestone-event-#{church.id}", "Church ceremony")

      html = render(view)
      [civil_style] = attr(html, "#timeline-milestone-event-#{civil.id}", "style")
      [church_style] = attr(html, "#timeline-milestone-event-#{church.id}", "style")

      # Fail-proof: if row assignment ever collapses back to one shared row (or the
      # `top:` offset stops depending on the row), both milestones render with the
      # identical `top:` style and this equality check catches it, well before anyone
      # has to eyeball a screenshot for overlapping text.
      refute civil_style == church_style

      assert {:error, {:live_redirect, %{to: to}}} =
               view |> element("#timeline-milestone-event-#{civil.id}") |> render_click()

      assert to == "/events/#{civil.id}/edit"

      # A fresh mount: the first click's live-redirect already exited `view`'s process.
      {:ok, view2, _html} = live(conn, ~p"/timeline")

      assert {:error, {:live_redirect, %{to: to2}}} =
               view2 |> element("#timeline-milestone-event-#{church.id}") |> render_click()

      assert to2 == "/events/#{church.id}/edit"
    end
  end

  describe "task label width matches the engine's min_gap (coordinator feedback, DR-68)" do
    test "a task-point label's max-width is calc'd from TimelineComponents.label_gap/0", %{
      conn: conn,
      scope: scope
    } do
      task =
        task!(scope, "Book venue", %{"deadline_kind" => "fixed", "deadline_date" => "2030-05-01"})

      {:ok, view, _html} = live(conn, ~p"/timeline")

      html = render(view)
      [style] = attr(html, "#timeline-point-#{task.id}", "style")

      # Fail-proof: drop the `max-width: ...` from the point's `style` (or from the
      # title/caption spans) and this fails — the width is never expressed any other
      # way (no fixed-width Tailwind class survives on the point any more).
      assert style =~ "max-width: #{WeddingPlannerWeb.TimelineComponents.label_max_width()}"
    end

    test "two points whose x-gap sits between the engine's own default and the label gap land in different rows",
         %{conn: conn, scope: scope} do
      # A precisely engineered gap: with the two "anchor" tasks far below/above today
      # fixing the axis span at exactly 874 days (independent of the real "today" this
      # runs on, since every date here is a relative offset), "left" and "right" land
      # `1350` x-units apart (`0..10_000` scale) — inside the engine's own default
      # `min_gap` (`1_200`, would keep them in one row) but below
      # `TimelineComponents.label_gap/0` (`1_500`, forces them apart). This is the
      # observable proof that `TimelineLive` passes `min_gap: label_gap()` through to
      # `Timeline.build/2`, not that its default happens to still work.
      today = Date.utc_today()

      task!(scope, "Anchor start", %{
        "deadline_kind" => "fixed",
        "deadline_date" => Date.add(today, -60)
      })

      task!(scope, "Anchor end", %{
        "deadline_kind" => "fixed",
        "deadline_date" => Date.add(today, 800)
      })

      left =
        task!(scope, "Choose wedding dress", %{
          "deadline_kind" => "fixed",
          "deadline_date" => Date.add(today, 300)
        })

      right =
        task!(scope, "Finalize seating chart draft", %{
          "deadline_kind" => "fixed",
          "deadline_date" => Date.add(today, 300 + 118)
        })

      {:ok, view, _html} = live(conn, ~p"/timeline")

      html = render(view)
      [left_style] = attr(html, "#timeline-point-#{left.id}", "style")
      [right_style] = attr(html, "#timeline-point-#{right.id}", "style")

      # Fail-proof: if `TimelineLive` stops passing `min_gap: label_gap()` (falling back
      # to the engine's own smaller default), these two land in the *same* row and this
      # fails.
      refute top_offset(left_style) == top_offset(right_style)
    end
  end

  describe "invoice milestones (BIL-06, example T5)" do
    @tag example: "T5"
    test "an unpaid invoice due 2030-03-01 shows as a milestone; marking it paid removes it live",
         %{conn: conn, scope: scope, category: category} do
      # Keeps `@timeline.range` non-nil once the invoice is paid and its milestone drops.
      task!(scope, "Book venue", %{"deadline_kind" => "fixed", "deadline_date" => "2030-04-01"})

      invoice =
        invoice_fixture(scope, category, %{"due_date" => ~D[2030-03-01]}, %{
          "amount_input" => "1500"
        })

      {:ok, view, _html} = live(conn, ~p"/timeline")

      assert has_element?(view, "#timeline-milestone-invoice-#{invoice.id}")
      assert has_element?(view, "#timeline-list-invoice-#{invoice.id}")

      {:ok, _} = Invoices.mark_paid(scope, invoice, ~D[2030-01-01])
      _ = :sys.get_state(view.pid)

      refute has_element?(view, "#timeline-milestone-invoice-#{invoice.id}")
      refute has_element?(view, "#timeline-list-invoice-#{invoice.id}")
    end
  end

  describe "tones (TSK-11, TSK-23)" do
    test "overdue, blocked (with the waits-on caption), done and actionable render via data-tone",
         %{conn: conn, scope: scope} do
      overdue =
        task!(scope, "Send invitations", %{
          "deadline_kind" => "fixed",
          "deadline_date" => "2020-01-01"
        })

      prerequisite =
        task!(scope, "Confirm venue", %{
          "deadline_kind" => "fixed",
          "deadline_date" => "2030-01-01"
        })

      blocked =
        task!(scope, "Print menus", %{"deadline_kind" => "fixed", "deadline_date" => "2030-02-01"})

      {:ok, _} = Tasks.add_dependency(scope, blocked, prerequisite)

      done =
        task!(scope, "Choose photographer", %{
          "deadline_kind" => "fixed",
          "deadline_date" => "2030-01-05",
          "status" => "done"
        })

      actionable =
        task!(scope, "Book florist", %{
          "deadline_kind" => "fixed",
          "deadline_date" => "2030-03-01"
        })

      {:ok, view, _html} = live(conn, ~p"/timeline")

      assert has_element?(view, "#timeline-point-#{overdue.id}[data-tone='overdue']")
      assert has_element?(view, "#timeline-point-#{blocked.id}[data-tone='blocked']")
      assert has_element?(view, "#timeline-point-#{blocked.id}", "waits on 'Confirm venue'")
      assert has_element?(view, "#timeline-point-#{done.id}[data-tone='done']")
      assert has_element?(view, "#timeline-point-#{actionable.id}[data-tone='actionable']")
    end
  end

  describe "arrows (DR-68's v3 fix)" do
    test "an arrow exists for a dependency with both ends dated, and adding one live adds the arrow",
         %{conn: conn, scope: scope} do
      prerequisite =
        task!(scope, "Confirm venue", %{
          "deadline_kind" => "fixed",
          "deadline_date" => "2030-01-01"
        })

      dependent =
        task!(scope, "Book caterer", %{
          "deadline_kind" => "fixed",
          "deadline_date" => "2030-02-01"
        })

      {:ok, _} = Tasks.add_dependency(scope, dependent, prerequisite)

      {:ok, view, _html} = live(conn, ~p"/timeline")

      assert has_element?(view, "#timeline-arrow-#{prerequisite.id}-#{dependent.id}")

      # Fail-proof 1: the arrow's y1 must equal the prerequisite point's own `data-y` —
      # both come from `TimelineComponents.row_y/1`, the single shared offset. Computing
      # the arrow's y with a different constant breaks this assertion without touching
      # any visible text.
      html = render(view)
      [prereq_y] = attr(html, "#timeline-point-#{prerequisite.id} [data-y]", "data-y")
      [dependent_y] = attr(html, "#timeline-point-#{dependent.id} [data-y]", "data-y")

      [arrow_y1] =
        attr(html, "#timeline-arrow-#{prerequisite.id}-#{dependent.id}", "data-y1")

      [arrow_y2] =
        attr(html, "#timeline-arrow-#{prerequisite.id}-#{dependent.id}", "data-y2")

      assert arrow_y1 == prereq_y
      assert arrow_y2 == dependent_y

      other =
        task!(scope, "Confirm florist", %{
          "deadline_kind" => "fixed",
          "deadline_date" => "2030-03-01"
        })

      {:ok, _} = Tasks.add_dependency(scope, other, prerequisite)
      _ = :sys.get_state(view.pid)

      assert has_element?(view, "#timeline-arrow-#{prerequisite.id}-#{other.id}")
    end
  end

  describe "selection (DR-44, DR-68)" do
    test "selecting a task highlights its chain, shows the panel, and survives a reload", %{
      conn: conn,
      scope: scope
    } do
      prerequisite =
        task!(scope, "Confirm venue", %{
          "deadline_kind" => "fixed",
          "deadline_date" => "2030-01-01"
        })

      dependent =
        task!(scope, "Book caterer", %{
          "deadline_kind" => "fixed",
          "deadline_date" => "2030-02-01"
        })

      independent =
        task!(scope, "Order cake", %{"deadline_kind" => "fixed", "deadline_date" => "2030-03-01"})

      {:ok, _} = Tasks.add_dependency(scope, dependent, prerequisite)

      {:ok, view, _html} = live(conn, ~p"/timeline?task=#{dependent.id}")

      assert has_element?(view, "#timeline-point-#{dependent.id}[data-in-chain='true']")
      assert has_element?(view, "#timeline-point-#{prerequisite.id}[data-in-chain='true']")
      assert has_element?(view, "#timeline-point-#{independent.id}[data-in-chain='false']")

      assert has_element?(view, "#timeline-panel", "Book caterer")

      assert has_element?(
               view,
               "#timeline-panel-open-in-tasks[href='/tasks?open=#{dependent.id}']"
             )

      {:ok, view2, _html2} = live(conn, ~p"/timeline?task=#{dependent.id}")
      assert has_element?(view2, "#timeline-panel", "Book caterer")
      assert has_element?(view2, "#timeline-point-#{prerequisite.id}[data-in-chain='true']")
    end
  end

  describe "relative deadlines resolve live (T4)" do
    test "setting an undated event's date moves a relative-deadline task from the side lane onto the axis live",
         %{conn: conn, scope: scope} do
      event = event!(scope, "Honeymoon departure")

      task =
        task!(scope, "Book honeymoon flights", %{
          "deadline_kind" => "relative",
          "deadline_amount" => "8",
          "deadline_unit" => "weeks",
          "deadline_direction" => "before",
          "deadline_event_id" => event.id
        })

      {:ok, view, _html} = live(conn, ~p"/timeline")

      assert has_element?(view, "#timeline-side-#{task.id}")
      refute has_element?(view, "#timeline-point-#{task.id}")

      {:ok, _} = Events.update_event(scope, event, %{"date" => "2030-06-01"})
      _ = :sys.get_state(view.pid)

      assert has_element?(view, "#timeline-point-#{task.id}")
      refute has_element?(view, "#timeline-side-#{task.id}")
    end
  end

  describe "dates are day-first (NFR-23)" do
    test "the panel and the list show dd/mm/yyyy", %{conn: conn, scope: scope} do
      task =
        task!(scope, "Book venue", %{"deadline_kind" => "fixed", "deadline_date" => "2030-05-13"})

      {:ok, view, _html} = live(conn, ~p"/timeline?task=#{task.id}")

      assert has_element?(view, "#timeline-panel", "13/05/2030")
      assert has_element?(view, "#timeline-list-task-#{task.id}", "13/05/2030")
    end
  end

  describe "phone toggle (TSK-22, NFR-31)" do
    test "Show timeline/Show list flips @phone_axis?, class-driven", %{conn: conn, scope: scope} do
      task!(scope, "Book venue", %{"deadline_kind" => "fixed", "deadline_date" => "2030-01-01"})

      {:ok, view, _html} = live(conn, ~p"/timeline")

      assert has_element?(view, "#timeline-list-wrapper.block")
      assert has_element?(view, "#timeline-axis-wrapper.hidden")

      view |> element("#timeline-show-axis") |> render_click()

      assert has_element?(view, "#timeline-axis-wrapper.block")
      assert has_element?(view, "#timeline-list-wrapper.hidden")

      view |> element("#timeline-show-list") |> render_click()

      assert has_element?(view, "#timeline-list-wrapper.block")
      assert has_element?(view, "#timeline-axis-wrapper.hidden")
    end
  end

  defp insert_user!(display_name) do
    %User{} |> User.changeset(%{display_name: display_name}) |> Repo.insert!()
  end

  defp insert_passkey!(user) do
    %Passkey{user_id: user.id, sign_count: 0}
    |> Passkey.registration_changeset(%{
      credential_id: :crypto.strong_rand_bytes(16),
      public_key: :crypto.strong_rand_bytes(16),
      name: "#{user.display_name}'s device",
      registered_at: DateTime.utc_now() |> DateTime.truncate(:second)
    })
    |> Repo.insert!()
  end
end
