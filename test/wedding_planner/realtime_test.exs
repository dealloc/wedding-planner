defmodule WeddingPlanner.RealtimeTest do
  use ExUnit.Case, async: true

  alias WeddingPlanner.Realtime

  describe "topic/1 and topic/2" do
    test "builds the collection topic" do
      assert Realtime.topic(:person) == "wp:person"
    end

    test "builds the record topic" do
      assert Realtime.topic(:person, 42) == "wp:person:42"
    end
  end

  describe "subscribe/broadcast round-trip" do
    test "a collection subscriber receives created/updated/deleted events" do
      :ok = Realtime.subscribe(:widget)

      Realtime.broadcast_change(:widget, {:created, %{id: 1, name: "Thing"}})
      assert_receive {Realtime, :widget, {:created, %{id: 1, name: "Thing"}}}

      Realtime.broadcast_change(:widget, {:updated, %{id: 1, name: "Thing 2"}})
      assert_receive {Realtime, :widget, {:updated, %{id: 1, name: "Thing 2"}}}

      Realtime.broadcast_change(:widget, {:deleted, 1})
      assert_receive {Realtime, :widget, {:deleted, 1}}

      :ok = Realtime.unsubscribe(:widget)
    end

    test "a record subscriber only hears about its own id" do
      :ok = Realtime.subscribe(:widget, 7)

      Realtime.broadcast_change(:widget, {:updated, %{id: 99, name: "Other widget"}})
      refute_receive {Realtime, :widget, _event}, 50

      Realtime.broadcast_change(:widget, {:updated, %{id: 7, name: "My widget"}})
      assert_receive {Realtime, :widget, {:updated, %{id: 7, name: "My widget"}}}

      :ok = Realtime.unsubscribe(:widget, 7)
    end

    # Its own resource atom, never `:shell_demo`: PubSub is global across async test
    # modules, and HomeLiveTest asserts on what `:shell_demo` broadcasts render.
    test "an event with no identifiable id only notifies the collection topic" do
      :ok = Realtime.subscribe(:realtime_test_no_id)

      Realtime.broadcast_change(:realtime_test_no_id, {:updated, %{message: "no id here"}})
      assert_receive {Realtime, :realtime_test_no_id, {:updated, %{message: "no id here"}}}

      :ok = Realtime.unsubscribe(:realtime_test_no_id)
    end
  end
end
