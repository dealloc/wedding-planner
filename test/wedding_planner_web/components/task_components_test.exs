defmodule WeddingPlannerWeb.TaskComponentsTest do
  @moduledoc """
  Pure formatting unit tests for `WeddingPlannerWeb.TaskComponents.deadline_text/1` and
  `owner_text/1` (`docs/modules/tasks-and-timeline.md` `TSK-02`/`TSK-03`, `DR-26` Q16) —
  no database, plain structs, to pin the exact wording independently of the LiveView.
  """
  use ExUnit.Case, async: true

  alias WeddingPlanner.Accounts.User
  alias WeddingPlanner.Categories.Category
  alias WeddingPlanner.Events.Event
  alias WeddingPlanner.Invoices.Invoice
  alias WeddingPlanner.Offers.Offer
  alias WeddingPlanner.Tasks.Task
  alias WeddingPlannerWeb.TaskComponents

  describe "deadline_text/1" do
    test "none" do
      assert TaskComponents.deadline_text(%Task{deadline_kind: :none}) == "No deadline"
    end

    test "fixed, day-first (NFR-23)" do
      task = %Task{deadline_kind: :fixed, deadline_date: ~D[2026-09-21]}
      assert TaskComponents.deadline_text(task) == "21/09/2026"
    end

    test "relative, resolved: '19/02/2028 · 12 weeks before Reception'" do
      task = %Task{
        deadline_kind: :relative,
        deadline_amount: 12,
        deadline_unit: :weeks,
        deadline_direction: :before,
        deadline_event_id: 1,
        deadline_event: %Event{id: 1, name: "Reception", date: ~D[2028-05-13]}
      }

      assert TaskComponents.deadline_text(task) == "19/02/2028 · 12 weeks before Reception"
    end

    test "relative, unresolved: TSK-03's own wording, not Format.date(nil)'s" do
      task = %Task{
        deadline_kind: :relative,
        deadline_amount: 8,
        deadline_unit: :weeks,
        deadline_direction: :before,
        deadline_event_id: 1,
        deadline_event: %Event{id: 1, name: "Civil ceremony", date: nil}
      }

      assert TaskComponents.deadline_text(task) ==
               "8 weeks before Civil ceremony — date not set"
    end

    test "relative, amount 0 resolved: 'On the day of Reception'" do
      task = %Task{
        deadline_kind: :relative,
        deadline_amount: 0,
        deadline_unit: :days,
        deadline_direction: :before,
        deadline_event_id: 1,
        deadline_event: %Event{id: 1, name: "Reception", date: ~D[2028-05-13]}
      }

      assert TaskComponents.deadline_text(task) == "13/05/2028 · On the day of Reception"
    end

    test "singular unit wording" do
      task = %Task{
        deadline_kind: :relative,
        deadline_amount: 1,
        deadline_unit: :weeks,
        deadline_direction: :after,
        deadline_event_id: 1,
        deadline_event: %Event{id: 1, name: "Dinner", date: nil}
      }

      assert TaskComponents.deadline_text(task) == "1 week after Dinner — date not set"
    end
  end

  describe "owner_text/1" do
    test "shared" do
      assert TaskComponents.owner_text(%Task{owner_shared: true}) == "Both"
    end

    test "nobody" do
      assert TaskComponents.owner_text(%Task{owner_id: nil, owner_shared: false}) == "Nobody"
    end

    test "a specific user" do
      task = %Task{owner_id: 1, owner_shared: false, owner: %User{display_name: "Bo"}}
      assert TaskComponents.owner_text(task) == "Bo"
    end
  end

  describe "owner_options/1" do
    test "Nobody and Both come first, then users by the order given" do
      users = [%User{id: 2, display_name: "Bo"}, %User{id: 1, display_name: "Wannes"}]

      assert TaskComponents.owner_options(users) == [
               {"Nobody", ""},
               {"Both", "shared"},
               {"Bo", "2"},
               {"Wannes", "1"}
             ]
    end
  end

  describe "link_options/4 (DR-26 Q17/Q18, task 32; DR-8/DR-69, task 78)" do
    test "groups events, categories, offers and invoices into their own optgroups, value encoding the type" do
      events = [%Event{id: 3, name: "Reception"}]
      categories = [%Category{id: 5, name: "Venue"}]

      offers = [
        %Offer{id: 7, vendor_name: "Venue A", category: %Category{name: "Venue"}}
      ]

      invoices = [
        %Invoice{id: 9, label: "Venue deposit", category: %Category{name: "Venue"}}
      ]

      assert TaskComponents.link_options(events, categories, offers, invoices) == [
               {"Events", [{"Reception", "event:3"}]},
               {"Categories", [{"Venue", "category:5"}]},
               {"Offers", [{"Venue — Venue A", "offer:7"}]},
               {"Invoices", [{"Venue — Venue deposit", "invoice:9"}]}
             ]
    end

    test "empty lists still produce all four (empty) groups" do
      assert TaskComponents.link_options([], [], [], []) == [
               {"Events", []},
               {"Categories", []},
               {"Offers", []},
               {"Invoices", []}
             ]
    end
  end

  describe "link_value/1 (DR-8/DR-69, task 78)" do
    test "an offer link" do
      form =
        %Task{}
        |> Ecto.Changeset.change(link_offer_id: 7)
        |> Phoenix.Component.to_form()

      assert TaskComponents.link_value(form) == "offer:7"
    end

    test "an invoice link" do
      form =
        %Task{}
        |> Ecto.Changeset.change(link_invoice_id: 9)
        |> Phoenix.Component.to_form()

      assert TaskComponents.link_value(form) == "invoice:9"
    end
  end
end
