defmodule WeddingPlanner.Tasks.TaskTest do
  @moduledoc """
  `docs/modules/tasks-and-timeline.md` TSK-01/TSK-02, `06-decisions.md` D-28 — pure
  changeset shape rules, no `Ecto.Repo` involved (the `DR-22` owner-*assignable* check
  lives in `WeddingPlanner.Tasks`, not here — see the schema's own moduledoc).
  """
  use ExUnit.Case, async: true

  alias WeddingPlanner.Tasks.Task

  describe "title (TSK-01)" do
    test "is required" do
      changeset = Task.changeset(%Task{}, %{"title" => ""})
      assert "can't be blank" in errors_on(changeset).title
    end

    test "is trimmed before validation" do
      changeset = Task.changeset(%Task{}, %{"title" => "  Book caterer  "})
      assert Ecto.Changeset.get_change(changeset, :title) == "Book caterer"
    end

    test "blank after trimming is rejected" do
      changeset = Task.changeset(%Task{}, %{"title" => "   "})
      assert "can't be blank" in errors_on(changeset).title
    end

    test "rejects more than 200 characters" do
      changeset = Task.changeset(%Task{}, %{"title" => String.duplicate("a", 201)})
      assert "should be at most 200 character(s)" in errors_on(changeset).title
    end

    test "accepts exactly 200 characters" do
      changeset = Task.changeset(%Task{}, %{"title" => String.duplicate("a", 200)})
      refute Map.has_key?(errors_on(changeset), :title)
    end
  end

  describe "notes" do
    test "blank notes are stored as nil, not an empty string" do
      changeset = Task.changeset(%Task{}, %{"title" => "Book caterer", "notes" => "   "})
      assert Ecto.Changeset.get_field(changeset, :notes) == nil
    end

    test "notes are trimmed" do
      changeset =
        Task.changeset(%Task{}, %{"title" => "Book caterer", "notes" => "  Bring cake  "})

      assert Ecto.Changeset.get_field(changeset, :notes) == "Bring cake"
    end
  end

  describe "owner (TSK-01, D-28) — exactly one of {user, shared, nobody}" do
    test "neither set is valid (unassigned)" do
      changeset = Task.changeset(%Task{}, %{"title" => "Book caterer"})
      assert changeset.valid?
      assert Ecto.Changeset.get_field(changeset, :owner_id) == nil
      assert Ecto.Changeset.get_field(changeset, :owner_shared) == false
    end

    test "owner_id alone is valid" do
      changeset = Task.changeset(%Task{}, %{"title" => "Book caterer", "owner_id" => 1})
      assert changeset.valid?
    end

    test "owner_shared alone is valid" do
      changeset =
        Task.changeset(%Task{}, %{"title" => "Book caterer", "owner_shared" => true})

      assert changeset.valid?
    end

    test "owner_id and owner_shared together is rejected" do
      changeset =
        Task.changeset(%Task{}, %{
          "title" => "Book caterer",
          "owner_id" => 1,
          "owner_shared" => true
        })

      refute changeset.valid?
      assert errors_on(changeset).owner_id
    end
  end

  describe "deadline kind :none (TSK-02)" do
    test "clears every deadline field, even if attrs try to set them" do
      changeset =
        Task.changeset(%Task{}, %{
          "title" => "Book caterer",
          "deadline_kind" => "none",
          "deadline_date" => "2028-01-01",
          "deadline_amount" => "5",
          "deadline_unit" => "days",
          "deadline_direction" => "before",
          "deadline_event_id" => 1
        })

      assert changeset.valid?
      assert Ecto.Changeset.get_field(changeset, :deadline_kind) == :none
      assert Ecto.Changeset.get_field(changeset, :deadline_date) == nil
      assert Ecto.Changeset.get_field(changeset, :deadline_amount) == nil
      assert Ecto.Changeset.get_field(changeset, :deadline_unit) == nil
      assert Ecto.Changeset.get_field(changeset, :deadline_direction) == nil
      assert Ecto.Changeset.get_field(changeset, :deadline_event_id) == nil
    end
  end

  describe "deadline kind :fixed (TSK-02)" do
    test "requires a date" do
      changeset =
        Task.changeset(%Task{}, %{"title" => "Book caterer", "deadline_kind" => "fixed"})

      refute changeset.valid?
      assert "can't be blank" in errors_on(changeset).deadline_date
    end

    test "valid with a date" do
      changeset =
        Task.changeset(%Task{}, %{
          "title" => "Book caterer",
          "deadline_kind" => "fixed",
          "deadline_date" => "2028-05-13"
        })

      assert changeset.valid?
      assert Ecto.Changeset.get_field(changeset, :deadline_date) == ~D[2028-05-13]
    end

    test "clears relative-only fields even if attrs try to set them" do
      changeset =
        Task.changeset(%Task{}, %{
          "title" => "Book caterer",
          "deadline_kind" => "fixed",
          "deadline_date" => "2028-05-13",
          "deadline_amount" => "12",
          "deadline_unit" => "weeks",
          "deadline_direction" => "before",
          "deadline_event_id" => 7
        })

      assert changeset.valid?
      assert Ecto.Changeset.get_field(changeset, :deadline_amount) == nil
      assert Ecto.Changeset.get_field(changeset, :deadline_unit) == nil
      assert Ecto.Changeset.get_field(changeset, :deadline_direction) == nil
      assert Ecto.Changeset.get_field(changeset, :deadline_event_id) == nil
    end
  end

  describe "deadline kind :relative (TSK-02, TSK-03)" do
    test "requires amount, unit, direction and an event" do
      changeset =
        Task.changeset(%Task{}, %{"title" => "Send invitations", "deadline_kind" => "relative"})

      refute changeset.valid?
      errors = errors_on(changeset)
      assert "can't be blank" in errors.deadline_amount
      assert "can't be blank" in errors.deadline_unit
      assert "can't be blank" in errors.deadline_direction
      assert "can't be blank" in errors.deadline_event_id
    end

    test "rejects a negative amount" do
      changeset =
        Task.changeset(%Task{}, %{
          "title" => "Send invitations",
          "deadline_kind" => "relative",
          "deadline_amount" => "-1",
          "deadline_unit" => "weeks",
          "deadline_direction" => "before",
          "deadline_event_id" => 1
        })

      refute changeset.valid?
      assert "must be greater than or equal to 0" in errors_on(changeset).deadline_amount
    end

    test "accepts an amount of 0 (\"on the day of\", Q16/DR-26)" do
      changeset =
        Task.changeset(%Task{}, %{
          "title" => "Send invitations",
          "deadline_kind" => "relative",
          "deadline_amount" => "0",
          "deadline_unit" => "days",
          "deadline_direction" => "before",
          "deadline_event_id" => 1
        })

      assert changeset.valid?
    end

    test "valid with every field set, unit stored exactly as entered (Q16, no normalisation)" do
      changeset =
        Task.changeset(%Task{}, %{
          "title" => "Send invitations",
          "deadline_kind" => "relative",
          "deadline_amount" => "12",
          "deadline_unit" => "weeks",
          "deadline_direction" => "before",
          "deadline_event_id" => 1
        })

      assert changeset.valid?
      assert Ecto.Changeset.get_field(changeset, :deadline_unit) == :weeks
    end

    test "clears deadline_date even if attrs try to set it" do
      changeset =
        Task.changeset(%Task{}, %{
          "title" => "Send invitations",
          "deadline_kind" => "relative",
          "deadline_date" => "2028-01-01",
          "deadline_amount" => "12",
          "deadline_unit" => "weeks",
          "deadline_direction" => "before",
          "deadline_event_id" => 1
        })

      assert changeset.valid?
      assert Ecto.Changeset.get_field(changeset, :deadline_date) == nil
    end
  end

  describe "switching kind clears the other kind's fields" do
    test "relative -> fixed drops the stale relative fields from an existing row" do
      existing = %Task{
        title: "Send invitations",
        deadline_kind: :relative,
        deadline_amount: 12,
        deadline_unit: :weeks,
        deadline_direction: :before,
        deadline_event_id: 3
      }

      changeset =
        Task.changeset(existing, %{"deadline_kind" => "fixed", "deadline_date" => "2028-01-01"})

      assert changeset.valid?
      assert Ecto.Changeset.get_field(changeset, :deadline_date) == ~D[2028-01-01]
      assert Ecto.Changeset.get_field(changeset, :deadline_amount) == nil
      assert Ecto.Changeset.get_field(changeset, :deadline_unit) == nil
      assert Ecto.Changeset.get_field(changeset, :deadline_direction) == nil
      assert Ecto.Changeset.get_field(changeset, :deadline_event_id) == nil
    end

    test "fixed -> none drops the fixed date from an existing row" do
      existing = %Task{
        title: "Book caterer",
        deadline_kind: :fixed,
        deadline_date: ~D[2028-01-01]
      }

      changeset = Task.changeset(existing, %{"deadline_kind" => "none"})

      assert changeset.valid?
      assert Ecto.Changeset.get_field(changeset, :deadline_kind) == :none
      assert Ecto.Changeset.get_field(changeset, :deadline_date) == nil
    end
  end

  describe "link (TSK-01, Q17/DR-26 — task 32 adds the category target)" do
    test "a task with no link is valid" do
      changeset = Task.changeset(%Task{}, %{"title" => "Book caterer"})
      assert changeset.valid?
    end

    test "a task linked to one event is valid" do
      changeset = Task.changeset(%Task{}, %{"title" => "Book venue", "link_event_id" => 1})
      assert changeset.valid?
      assert Ecto.Changeset.get_field(changeset, :link_event_id) == 1
    end

    test "a task linked to one category is valid" do
      changeset = Task.changeset(%Task{}, %{"title" => "Book venue", "link_category_id" => 1})
      assert changeset.valid?
      assert Ecto.Changeset.get_field(changeset, :link_category_id) == 1
    end

    test "setting both an event and a category link is rejected" do
      changeset =
        Task.changeset(%Task{}, %{
          "title" => "Book venue",
          "link_event_id" => 1,
          "link_category_id" => 2
        })

      refute changeset.valid?
      assert "at most one link may be set" in errors_on(changeset).link_event_id
      assert "at most one link may be set" in errors_on(changeset).link_category_id
    end
  end

  defp errors_on(changeset) do
    Ecto.Changeset.traverse_errors(changeset, fn {message, opts} ->
      Regex.replace(~r"%{(\w+)}", message, fn _, key ->
        opts |> Keyword.get(String.to_existing_atom(key), key) |> to_string()
      end)
    end)
  end
end
