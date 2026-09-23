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
end
