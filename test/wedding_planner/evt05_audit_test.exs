defmodule WeddingPlanner.Evt05AuditTest do
  @moduledoc """
  `DR-85`: EVT-05 completeness — closes `DR-5`. Two independent claims:

    1. **The tripwire.** Every schema module of `:wedding_planner` is scanned for a
       `belongs_to` association (or a field named `..._event_id`) that references
       `WeddingPlanner.Events.Event`; the set found must equal exactly today's five known
       references. A sixth one appearing here — and nowhere in
       `config :wedding_planner, :event_reference_providers` — is exactly the gap DR-85
       closes: this test fails loudly instead of a silently incomplete delete warning.

    2. **The configured list is exercised as configured.** Every other EVT-05 test
       (`events_test.exs`, `tasks_test.exs`, `invitations_test.exs`, `offers_lines_test.exs`)
       installs its providers via `Application.put_env/3`; this file **never does** — it
       reads `Application.get_env(:wedding_planner, :event_reference_providers)` exactly as
       `WeddingPlanner.Events.affected_references/1` does, so a provider dropped from
       `config/config.exs` shows up here and nowhere else.

  `async: false`: reads the shared, global application environment (not a copy).
  """
  use WeddingPlanner.DataCase, async: false

  import WeddingPlanner.OfferFixtures

  alias WeddingPlanner.Categories
  alias WeddingPlanner.Events
  alias WeddingPlanner.Events.Event
  alias WeddingPlanner.Guests
  alias WeddingPlanner.Invitations
  alias WeddingPlanner.Invitations.Invitation
  alias WeddingPlanner.Invitations.PlusOneOptOut
  alias WeddingPlanner.Log.Entry
  alias WeddingPlanner.Log.Query, as: LogQuery
  alias WeddingPlanner.Offers
  alias WeddingPlanner.Offers.OfferLine
  alias WeddingPlanner.Tasks
  alias WeddingPlanner.Tasks.Task

  # Today's five known references (DR-85). A new one here means a new provider and a new
  # detach step in `Events.delete_event/2` — never a silent sixth column.
  @expected_event_references MapSet.new([
                               {Task, :deadline_event_id},
                               {Task, :link_event_id},
                               {Invitation, :event_id},
                               {PlusOneOptOut, :event_id},
                               {OfferLine, :event_id}
                             ])

  # -- tripwire (DR-85 (1)) ------------------------------------------------------------------

  describe "tripwire: every reference to WeddingPlanner.Events.Event has a provider" do
    test "belongs_to associations whose related is Event equal exactly the five known references" do
      assert_no_new_references(event_associations())
    end

    test "fields ending in event_id equal exactly the five known references" do
      assert_no_new_references(event_id_fields())
    end
  end

  defp assert_no_new_references(found) do
    assert found == @expected_event_references,
           "a new reference to events: add an EVT-05 provider to config :wedding_planner, " <>
             ":event_reference_providers and a detach step to Events.delete_event/2 " <>
             "(found #{inspect(MapSet.to_list(found))}, expected " <>
             "#{inspect(MapSet.to_list(@expected_event_references))})"
  end

  defp schema_modules do
    {:ok, modules} = :application.get_key(:wedding_planner, :modules)
    # `function_exported?/3` is false for a module not yet loaded (a fresh run of this file
    # alone), so load each one first.
    Enum.filter(modules, &(Code.ensure_loaded?(&1) and function_exported?(&1, :__schema__, 1)))
  end

  defp event_associations do
    for module <- schema_modules(),
        assoc_name <- module.__schema__(:associations),
        %Ecto.Association.BelongsTo{related: Event, owner_key: key} <-
          [module.__schema__(:association, assoc_name)],
        into: MapSet.new(),
        do: {module, key}
  end

  defp event_id_fields do
    for module <- schema_modules(),
        field <- module.__schema__(:fields),
        String.ends_with?(Atom.to_string(field), "event_id"),
        into: MapSet.new(),
        do: {module, field}
  end

  # -- the configured list, and an end-to-end deletion (DR-85 (2), (3)) --------------------

  describe "an event referenced by all five kinds of row" do
    setup do
      scope = scope_fixture()
      {:ok, event} = Events.create_event(scope, %{"couple_attends" => false, "name" => "Brunch"})

      {:ok, anchored_task} =
        Tasks.create_task(scope, %{
          "title" => "Send invitations",
          "deadline_kind" => "relative",
          "deadline_amount" => "2",
          "deadline_unit" => "weeks",
          "deadline_direction" => "before",
          "deadline_event_id" => event.id
        })

      {:ok, linked_task} =
        Tasks.create_task(scope, %{"title" => "Book florist", "link_event_id" => event.id})

      {:ok, host} =
        Guests.create_person(scope, %{"first_name" => "Anna", "last_name" => "Peeters"})

      {:ok, plus_one} = Guests.add_plus_one(scope, host, %{})

      {:ok, invitation} = Invitations.set_invitation_status(scope, host, event, :accepted)
      {:ok, opt_out} = Invitations.set_opt_out(scope, plus_one, event, true)

      category = category_fixture(scope)
      {:ok, service} = Categories.create_service(scope, category, %{"name" => "Catering"})
      offer = offer_fixture(scope, category, %{"vendor_name" => "Venue A"})

      {:ok, line} =
        Offers.create_line(scope, offer, %{
          "service_id" => service.id,
          "state" => "mandatory",
          "basis" => "per_adult",
          "event_id" => event.id,
          "amount_input" => "85"
        })

      %{
        scope: scope,
        event: event,
        anchored_task: anchored_task,
        linked_task: linked_task,
        host: host,
        plus_one: plus_one,
        invitation: invitation,
        opt_out: opt_out,
        offer: offer,
        offer_line: line
      }
    end

    test "affected_references/1 has five entries whose labels name each kind", %{event: event} do
      refs = Events.affected_references(event)

      assert length(refs) == 5

      assert refs == [
               %{
                 label: "1 task with a deadline relative to this event (deadline becomes none)",
                 count: 1
               },
               %{label: "1 task linked to this event (link removed)", count: 1},
               %{label: "1 invitation", count: 1},
               %{label: "1 +1 opt-out", count: 1},
               %{label: "1 offer line (it becomes invalid)", count: 1}
             ]
    end

    test "the configured list has five functions, one per reference kind, each firing on this event",
         %{event: event} do
      providers = Application.get_env(:wedding_planner, :event_reference_providers)

      assert is_list(providers)
      assert length(providers) == 5

      fired = providers |> Enum.map(& &1.(event)) |> Enum.reject(&is_nil/1)
      assert length(fired) == 5
    end

    test "delete_event/2 succeeds, detaching every reference and leaving one child per affected row",
         %{
           scope: scope,
           event: event,
           anchored_task: anchored_task,
           linked_task: linked_task,
           invitation: invitation,
           opt_out: opt_out,
           offer: offer,
           offer_line: line
         } do
      assert {:ok, deleted} = Events.delete_event(scope, event)
      assert deleted.id == event.id
      assert_raise Ecto.NoResultsError, fn -> Events.get_event!(event.id) end

      # No row references the event id afterwards.
      reloaded_anchored = Tasks.get_task!(anchored_task.id)
      assert reloaded_anchored.deadline_kind == :none
      assert is_nil(reloaded_anchored.deadline_event_id)

      reloaded_linked = Tasks.get_task!(linked_task.id)
      assert is_nil(reloaded_linked.link_event_id)

      refute Repo.get(Invitation, invitation.id)
      refute Repo.get(PlusOneOptOut, opt_out.id)

      # The offer line still exists, invalid (never deleted, D-26).
      reloaded_line = Repo.get!(OfferLine, line.id)
      assert is_nil(reloaded_line.event_id)
      assert OfferLine.invalid?(reloaded_line)
      assert Offers.get_offer!(offer.id)

      # One child entry per affected row (task ×2, person ×2 — host and +1 — offer ×1),
      # plus the event's own entry.
      summary =
        Repo.all(Entry)
        |> Enum.find(
          &(is_nil(&1.entity_type) and &1.description == "Wannes deleted event 'Brunch'")
        )

      assert summary

      children = LogQuery.children(summary.id)
      assert length(children) == 6

      assert Enum.count(children, &(&1.entity_type == "task")) == 2
      assert Enum.count(children, &(&1.entity_type == "person")) == 2
      assert Enum.count(children, &(&1.entity_type == "offer")) == 1
      assert Enum.count(children, &(&1.entity_type == "event")) == 1
    end
  end
end
