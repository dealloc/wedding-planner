defmodule WeddingPlanner.Seeds.People do
  @moduledoc """
  `DR-26` Q4 demo guest list: 44 people — the scale the `/people` screens were judged at
  (`.claude/design/ui-decisions.md` §5, "44 people") — across four groups of varied
  type labels (household, household, circle, colleagues) plus six ungrouped, with a
  realistic mix of Flemish names including particles (Van Damme, De Smet, Vanden
  Broeck), a one-word name ("Oma"), children, and every `want_tier`/`certainty` value
  represented. No invitations (out of slice). Idempotent: runs only while the `persons`
  table is empty — see `priv/repo/seeds.exs`.

  ## +1s (task 37, `PER-10`–`PER-16`, `DR-32`/`DR-34`)

  A separate, independently idempotent block (`seed_plus_ones/1`, guarded by "no person
  has a `host_id` yet" rather than "no persons exist", so it also runs against a DB
  seeded before this task) adds 8 +1s across grouped and ungrouped hosts — through
  `Guests.add_plus_one/3`, so each gets a real activity-log entry (`XC-10`) — covering
  unnamed *possible*, unnamed *confirmed*, named *confirmed*, one *child* +1, and one
  host with two +1s.
  """

  import Ecto.Query

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

    seed_plus_ones(scope)

    :ok
  end

  # Runs only while no person has a `host_id` yet — independent of the block above, so
  # this also backfills +1s on a dev DB that was seeded before task 37.
  defp seed_plus_ones(scope) do
    if Repo.exists?(from(p in Person, where: not is_nil(p.host_id))) do
      IO.puts("skipping +1s — already has data")
    else
      hosts = Guests.list_persons(%{})
      created = Enum.map(plus_one_plan(), &add_plus_one!(scope, hosts, &1))
      IO.puts("people: created #{length(created)} +1s")
    end
  end

  defp add_plus_one!(scope, hosts, {first, last, attrs}) do
    host = find_host!(hosts, first, last)
    {:ok, plus_one} = Guests.add_plus_one(scope, host, attrs)
    plus_one
  end

  defp find_host!(hosts, first, last) do
    Enum.find(hosts, fn p -> p.first_name == first and p.last_name == last end) ||
      raise "seed +1s: host #{first} #{last} not found — check people.exs seed names"
  end

  # `{host_first_name, host_last_name, plus_one_attrs}` — a mix of unnamed possible,
  # unnamed confirmed, named confirmed, one child +1, and one host (Jasper Van Damme)
  # with two +1s, spread across grouped and ungrouped hosts.
  defp plus_one_plan do
    [
      {"Karel", "Peeters", %{plus_one_status: :possible}},
      {"Mieke", "Peeters",
       %{first_name: "Tomas", last_name: "Verlinden", plus_one_status: :confirmed}},
      {"Jasper", "Van Damme", %{plus_one_status: :possible}},
      {"Jasper", "Van Damme",
       %{first_name: "Kaat", last_name: "Willems", plus_one_status: :confirmed}},
      {"Pieter", "De Smet", %{plus_one_status: :confirmed}},
      {"Sander", "De Backer",
       %{first_name: "Lien", last_name: "De Backer", plus_one_status: :confirmed}},
      {"Nora", "De Wilde", %{plus_one_status: :possible}},
      {"Thijs", "Van der Linden",
       %{
         first_name: "Noor",
         last_name: "Van der Linden",
         plus_one_status: :confirmed,
         age_category: :child
       }}
    ]
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
