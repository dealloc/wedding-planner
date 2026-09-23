defmodule WeddingPlanner.Guests.PersonTest do
  @moduledoc """
  `WeddingPlanner.Guests.Person`'s changeset: `PER-02`, `D-29`.
  """
  use WeddingPlanner.DataCase, async: true

  alias WeddingPlanner.Guests.Person

  describe "changeset/2 — name presence (PER-02)" do
    test "requires at least one of first/last name" do
      changeset = Person.changeset(%Person{}, %{})

      errors = errors_on(changeset)
      assert "must provide a first or last name" in errors.first_name
      assert "must provide a first or last name" in errors.last_name
    end

    test "a first name alone is valid" do
      changeset = Person.changeset(%Person{}, %{"first_name" => "Bo"})
      assert changeset.valid?
    end

    test "a last name alone is valid" do
      changeset = Person.changeset(%Person{}, %{"last_name" => "Peeters"})
      assert changeset.valid?
    end

    test "blank strings for both names are treated as absent" do
      changeset = Person.changeset(%Person{}, %{"first_name" => "  ", "last_name" => ""})

      errors = errors_on(changeset)
      assert "must provide a first or last name" in errors.first_name
      assert "must provide a first or last name" in errors.last_name
    end
  end

  describe "changeset/2 — name trimming" do
    test "trims surrounding whitespace from both names" do
      changeset =
        Person.changeset(%Person{}, %{"first_name" => "  Anna  ", "last_name" => "  Peeters "})

      assert Ecto.Changeset.get_change(changeset, :first_name) == "Anna"
      assert Ecto.Changeset.get_change(changeset, :last_name) == "Peeters"
    end

    test "a blank first name becomes nil, not an empty string" do
      changeset =
        Person.changeset(%Person{}, %{"first_name" => "   ", "last_name" => "Peeters"})

      assert Ecto.Changeset.get_field(changeset, :first_name) == nil
    end
  end

  describe "changeset/2 — fixed enums" do
    test "rejects an age category outside :adult/:child" do
      changeset =
        Person.changeset(%Person{}, %{"first_name" => "Bo", "age_category" => "teenager"})

      assert "is invalid" in errors_on(changeset).age_category
    end

    test "rejects a want tier outside the four fixed atoms" do
      changeset = Person.changeset(%Person{}, %{"first_name" => "Bo", "want_tier" => "kinda"})
      assert "is invalid" in errors_on(changeset).want_tier
    end

    test "rejects a certainty outside the three fixed atoms" do
      changeset = Person.changeset(%Person{}, %{"first_name" => "Bo", "certainty" => "sure"})
      assert "is invalid" in errors_on(changeset).certainty
    end

    test "accepts every fixed atom for each enum" do
      for age <- [:adult, :child],
          want <- [:yes, :maybe, :no, :obligated],
          certainty <- [:certain, :likely, :uncertain] do
        changeset =
          Person.changeset(%Person{}, %{
            "first_name" => "Bo",
            "age_category" => Atom.to_string(age),
            "want_tier" => Atom.to_string(want),
            "certainty" => Atom.to_string(certainty)
          })

        assert changeset.valid?, inspect(errors_on(changeset))
      end
    end

    test "a bare struct already carries the DR-26 Q6 defaults (adult/yes/likely)" do
      assert %Person{age_category: :adult, want_tier: :yes, certainty: :likely} = %Person{}
    end
  end

  describe "changeset/2 — group" do
    test "group_id is optional" do
      changeset = Person.changeset(%Person{}, %{"first_name" => "Bo"})
      assert changeset.valid?
    end

    test "Person.changeset/2 alone does not check the group exists (that's WeddingPlanner.Guests.change_person/2's job — see its moduledoc)" do
      changeset = Person.changeset(%Person{}, %{"first_name" => "Bo", "group_id" => 999_999})
      assert changeset.valid?
    end
  end

  describe "display_name/1 (PER-02)" do
    test "first name only" do
      assert Person.display_name(%Person{first_name: "Bo", last_name: nil}) == "Bo"
    end

    test "last name only" do
      assert Person.display_name(%Person{first_name: nil, last_name: "Oma"}) == "Oma"
    end

    test "both first and last name" do
      assert Person.display_name(%Person{first_name: "Anna", last_name: "Peeters"}) ==
               "Anna Peeters"
    end
  end

  # -- +1s (PER-10 through PER-16, DR-32) ----------------------------------------------

  describe "plus_one?/1 and name_known?/1" do
    test "a non-+1 is never a plus_one, and its name is always known" do
      person = %Person{host_id: nil, first_name: "Anna"}
      refute Person.plus_one?(person)
      assert Person.name_known?(person)
    end

    test "a +1 with host_id set is a plus_one" do
      assert Person.plus_one?(%Person{host_id: 1})
    end

    test "an unnamed +1's name is not known; a named one's is" do
      unnamed = %Person{host_id: 1, first_name: nil, last_name: nil}
      refute Person.name_known?(unnamed)

      named_first = %Person{host_id: 1, first_name: "Tom", last_name: nil}
      assert Person.name_known?(named_first)

      named_last = %Person{host_id: 1, first_name: nil, last_name: "Wils"}
      assert Person.name_known?(named_last)
    end
  end

  describe "changeset/2 — a +1 (PER-10, PER-11, PER-12, PER-15)" do
    test "an unnamed, possible +1 is valid (no name required)" do
      plus_one = %Person{host_id: 1}
      changeset = Person.changeset(plus_one, %{"plus_one_status" => "possible"})
      assert changeset.valid?
    end

    test "plus_one_status is required" do
      plus_one = %Person{host_id: 1}
      changeset = Person.changeset(plus_one, %{})
      assert "can't be blank" in errors_on(changeset).plus_one_status
    end

    test "want_tier in attrs is refused with 'is inherited from the host'" do
      plus_one = %Person{host_id: 1, want_tier: :yes}

      changeset =
        Person.changeset(plus_one, %{"plus_one_status" => "possible", "want_tier" => "no"})

      refute changeset.valid?
      assert "is inherited from the host" in errors_on(changeset).want_tier
    end

    test "certainty in attrs is refused with 'is inherited from the host'" do
      plus_one = %Person{host_id: 1, certainty: :likely}

      changeset =
        Person.changeset(plus_one, %{"plus_one_status" => "possible", "certainty" => "certain"})

      refute changeset.valid?
      assert "is inherited from the host" in errors_on(changeset).certainty
    end

    test "group_id in attrs is refused with 'is inherited from the host'" do
      plus_one = %Person{host_id: 1}
      changeset = Person.changeset(plus_one, %{"plus_one_status" => "possible", "group_id" => 9})

      refute changeset.valid?
      assert "is inherited from the host" in errors_on(changeset).group_id
    end

    test "an atom-keyed inherited field is refused too, not just string-keyed" do
      plus_one = %Person{host_id: 1}
      changeset = Person.changeset(plus_one, %{plus_one_status: :possible, want_tier: :yes})

      refute changeset.valid?
      assert "is inherited from the host" in errors_on(changeset).want_tier
    end

    test "clearing both names on an existing named +1 is valid (back to unnamed)" do
      plus_one = %Person{
        host_id: 1,
        first_name: "Tom",
        last_name: "Wils",
        plus_one_status: :confirmed
      }

      changeset =
        Person.changeset(plus_one, %{"first_name" => "", "last_name" => ""})

      assert changeset.valid?
      assert Ecto.Changeset.get_field(changeset, :first_name) == nil
      assert Ecto.Changeset.get_field(changeset, :last_name) == nil
    end

    test "age category and notes are cast normally" do
      plus_one = %Person{host_id: 1}

      changeset =
        Person.changeset(plus_one, %{
          "plus_one_status" => "possible",
          "age_category" => "child",
          "notes" => "vegetarian"
        })

      assert changeset.valid?
      assert Ecto.Changeset.get_field(changeset, :age_category) == :child
      assert Ecto.Changeset.get_field(changeset, :notes) == "vegetarian"
    end

    test "host_id is never cast, even if present in attrs" do
      plus_one = %Person{host_id: 1}
      changeset = Person.changeset(plus_one, %{"plus_one_status" => "possible", "host_id" => 999})

      refute Ecto.Changeset.get_change(changeset, :host_id)
    end
  end

  describe "display_name/1 — +1s (PER-11)" do
    test "a named +1 shows its own name, same as any person" do
      plus_one = %Person{host_id: 1, first_name: "Tom", last_name: "Wils"}
      assert Person.display_name(plus_one) == "Tom Wils"
    end

    test "an unnamed +1 with :host preloaded shows '+1 of <host>'" do
      host = %Person{id: 1, first_name: "Anna", last_name: "Peeters"}
      plus_one = %Person{host_id: 1, first_name: nil, last_name: nil, host: host}

      assert Person.display_name(plus_one) == "+1 of Anna Peeters"
    end

    test "renaming the host changes the unnamed +1's derived name" do
      host = %Person{id: 1, first_name: "Anna", last_name: "Aerts"}
      plus_one = %Person{host_id: 1, host: host}

      assert Person.display_name(plus_one) == "+1 of Anna Aerts"

      renamed_host = %Person{host | last_name: "Peeters"}
      renamed_plus_one = %Person{plus_one | host: renamed_host}

      assert Person.display_name(renamed_plus_one) == "+1 of Anna Peeters"
    end

    test "an unnamed +1 without :host preloaded raises ArgumentError" do
      plus_one = %Person{id: 5, host_id: 1, first_name: nil, last_name: nil}

      assert_raise ArgumentError, ~r/needs :host preloaded/, fn ->
        Person.display_name(plus_one)
      end
    end
  end
end
