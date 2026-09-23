defmodule WeddingPlanner.Seeds.People do
  @moduledoc """
  `DR-26` Q4 demo guest list: 44 people — the scale the `/people` screens were judged at
  (`.claude/design/ui-decisions.md` §5, "44 people") — across four groups of varied
  type labels (household, household, circle, colleagues) plus six ungrouped, with a
  realistic mix of Flemish names including particles (Van Damme, De Smet, Vanden
  Broeck), a one-word name ("Oma"), children, and every `want_tier`/`certainty` value
  represented. No +1s, no invitations (out of slice). Idempotent: runs only while the
  `persons` table is empty — see `priv/repo/seeds.exs`.
  """

  alias WeddingPlanner.Accounts.Scope
  alias WeddingPlanner.Guests
  alias WeddingPlanner.Guests.Person
  alias WeddingPlanner.Repo

  @spec run(Scope.t()) :: :ok
  def run(%Scope{} = scope) do
    if Repo.aggregate(Person, :count) == 0 do
      grouped_count = groups() |> Enum.map(&seed_group(scope, &1)) |> Enum.sum()
      {:ok, ungrouped} = Guests.bulk_create_persons(scope, ungrouped_people(), %{})

      IO.puts(
        "people: created #{grouped_count + length(ungrouped)} people across " <>
          "#{length(groups())} groups + ungrouped"
      )
    else
      IO.puts("skipping people — already has data")
    end

    :ok
  end

  defp seed_group(scope, {name, type_label, members}) do
    {:ok, group} = Guests.create_group(scope, %{name: name, type_label: type_label})
    {:ok, created} = Guests.bulk_create_persons(scope, members, %{group_id: group.id})
    length(created)
  end

  defp groups do
    [
      {"Family Peeters", "household", family_peeters()},
      {"Family Van Damme", "household", family_van_damme()},
      {"University friends", "circle", university_friends()},
      {"Colleagues", "colleagues", colleagues()}
    ]
  end

  # 13 members — big enough for the grouped view and group-deletion-at-scale demos
  # (`.claude/design/ui-decisions.md` §5).
  defp family_peeters do
    [
      %{first_name: "Karel", last_name: "Peeters"},
      %{first_name: "Mieke", last_name: "Peeters"},
      %{first_name: "Jan", last_name: "Peeters"},
      %{first_name: "Griet", last_name: "Peeters", want_tier: :maybe, certainty: :uncertain},
      %{first_name: "Tom", last_name: "Peeters"},
      %{first_name: "Nele", last_name: "Peeters"},
      %{first_name: "Louise", last_name: "Peeters"},
      %{first_name: "Femke", last_name: "Peeters"},
      %{first_name: "Anna", last_name: "Peeters", age_category: :child},
      %{first_name: "Bo", last_name: "Peeters", age_category: :child},
      %{first_name: "Sam", last_name: "Peeters", age_category: :child},
      %{first_name: "Opa", last_name: "Peeters", want_tier: :obligated, certainty: :certain},
      %{first_name: "Oma", certainty: :certain}
    ]
  end

  defp family_van_damme do
    [
      %{first_name: "Jasper", last_name: "Van Damme"},
      %{first_name: "Ellen", last_name: "Van Damme"},
      %{first_name: "Ruben", last_name: "Van Damme"},
      %{first_name: "Sofie", last_name: "Van Damme"},
      %{first_name: "Mathias", last_name: "Van Damme"},
      %{first_name: "Charlotte", last_name: "Van Damme"},
      %{first_name: "Dries", last_name: "Van Damme"},
      %{first_name: "Julie", last_name: "Van Damme", age_category: :child},
      %{first_name: "Lars", last_name: "Van Damme", age_category: :child}
    ]
  end

  defp university_friends do
    [
      %{first_name: "Pieter", last_name: "De Smet"},
      %{first_name: "Hannah", last_name: "Vanden Broeck"},
      %{first_name: "Kobe", last_name: "Janssens"},
      %{first_name: "Lotte", last_name: "Willems"},
      %{first_name: "Niels", last_name: "Maes"},
      %{first_name: "Fien", last_name: "Claes"},
      %{first_name: "Arne", last_name: "Wouters"},
      %{first_name: "Emma", last_name: "Vermeulen"}
    ]
  end

  defp colleagues do
    [
      %{first_name: "Sander", last_name: "De Backer"},
      %{first_name: "Katrien", last_name: "Van Acker"},
      %{first_name: "Wout", last_name: "De Cock", certainty: :uncertain},
      %{first_name: "Tim", last_name: "Verhoeven", want_tier: :no, certainty: :uncertain},
      %{first_name: "Els", last_name: "Goossens"},
      %{first_name: "Bram", last_name: "De Ridder"},
      %{first_name: "Inge", last_name: "Coppens"},
      %{first_name: "Veerle", last_name: "Van den Berge"}
    ]
  end

  defp ungrouped_people do
    [
      %{first_name: "Nora", last_name: "De Wilde"},
      %{first_name: "Thijs", last_name: "Van der Linden"},
      %{first_name: "Marie", last_name: "Segers", want_tier: :maybe},
      %{first_name: "Victor", last_name: "Lemmens"},
      %{first_name: "Hanne", last_name: "Peeters"},
      %{first_name: "Oscar", last_name: "De Groote"}
    ]
  end
end
