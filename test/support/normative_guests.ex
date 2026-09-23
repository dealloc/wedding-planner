defmodule WeddingPlanner.NormativeGuests do
  @moduledoc """
  The two guest-list fixtures of `docs/07-normative-examples.md` as **real database
  rows**, written through the contexts (`WeddingPlanner.Guests`,
  `WeddingPlanner.Invitations`) — never raw inserts. Test support only; needs a
  sandboxed `WeddingPlanner.DataCase`. The guest-side counterpart of
  `WeddingPlanner.NormativeOfferRows`: together they let a test go real rows →
  `WeddingPlanner.Valuation.Snapshot.load/1` → the real engines, with no `headcount:`
  seam.

  Every function takes the scope the rows are written under
  (`WeddingPlanner.OfferFixtures.scope_fixture/1`). The contexts log what they write, so
  every call leaves `WeddingPlanner.Log` entries behind (one summary action per bulk
  write, one entry per person or invitation); they are expected and harmless — no
  engine reads the activity log.

  Neither fixture checks what is already in the database. Anyone else invited to the
  same event is counted too; the figures below hold only when the fixture's persons are
  the event's only guests.

  ## The shared Dinner fixture — `shared_dinner!/2`

  The docs' "Shared fixtures": event **Dinner**, preset **Likely** 72 adults + 6
  children = 78, preset **Minimum** 60 adults + 4 children = 64
  (`WeddingPlanner.NormativeExamples.shared_headcount/0`). The docs fix only those two
  figures, so the construction is the simplest one that meets both and invents nothing
  (task 24, `DR-26` D8):

  | Role                | Adults | Children | Certainty | Dinner   |
  |---------------------|--------|----------|-----------|----------|
  | `certain_adults`    | 60     |          | *certain* | *invited* |
  | `certain_children`  |        | 4        | *certain* | *invited* |
  | `likely_adults`     | 12     |          | *likely*  | *invited* |
  | `likely_children`   |        | 2        | *likely*  | *invited* |

  No *uncertain* person, no +1, no group, want tier *yes* (the schema default) on all
  78. So Minimum (*certain*) = 60 + 4 and Likely (*certain* or *likely*) = 72 + 6.

  **Its Maximum is a by-product, not a normative value.** With no *uncertain* person
  it happens to equal Likely (72 + 6), but the docs give no Maximum for this fixture and
  none may be asserted as one (`NormativeExamples.fixed_headcount/0` raises for it too).
  A test that needs a range builds its own.

  The offers of O1/O2/O4/O5 (`NormativeOfferRows.offer!/5`) must be entered on the
  **same** Dinner event the fixture invites to — `NormativeOfferRows.dinner!/1`
  finds-or-creates it, so pass its result to both.

  ## The headcount fixture — `h1!/2`, `with_plus_one!/3`, `uninvited!/2`

  The docs' separate ten-person fixture behind H1–H4. The docs fix only the statuses and
  certainties; the adult/child split and which accepted person hosts the +1 are this
  fixture's own, chosen to match the in-memory H1 snapshot of
  `WeddingPlanner.Valuation.HeadcountTest` (task 53) person for person, so both paths
  evaluate the same guest list:

  | Role                | Dinner     | Stored certainty | Age          |
  |---------------------|------------|------------------|--------------|
  | `accepted`          | *accepted* | *certain*, *likely*, *uncertain*, *uncertain* | adult, adult, adult, **child** |
  | `invited_certain`   | *invited*  | *certain* ×3     | adult ×3     |
  | `invited_likely`    | *invited*  | *likely* ×2      | adult, **child** |
  | `planned_uncertain` | *planned*  | *uncertain*      | **child**    |

  giving, for Dinner, Minimum 6 + 1 = 7, Likely 7 + 2 = 9, Maximum 7 + 3 = 10 (H1).
  `plus_one_host` is the third accepted person — accepted, stored *uncertain*, adult —
  so a *confirmed* +1 can only become *certain* through `HC-04` via its host, never
  through a stored certainty. `with_plus_one!/3` gives that person an unnamed **adult**
  +1, no opt-out: H2 (*confirmed*, 8 / 10 / 11) or H3 (*possible*, 7 / 9 / 11).
  `uninvited!/2` is H4's person.
  """

  alias WeddingPlanner.Accounts.Scope
  alias WeddingPlanner.Events.Event
  alias WeddingPlanner.Guests
  alias WeddingPlanner.Guests.Person
  alias WeddingPlanner.Invitations

  @typedoc "The shared Dinner fixture's persons by role (see the moduledoc's table)."
  @type shared :: %{
          persons: [Person.t()],
          certain_adults: [Person.t()],
          certain_children: [Person.t()],
          likely_adults: [Person.t()],
          likely_children: [Person.t()]
        }

  @typedoc "H1's ten persons by role (see the moduledoc's table), plus H2/H3's host."
  @type h1 :: %{
          persons: [Person.t()],
          accepted: [Person.t()],
          invited_certain: [Person.t()],
          invited_likely: [Person.t()],
          planned_uncertain: [Person.t()],
          plus_one_host: Person.t()
        }

  # {role, count, certainty, age} — the shared fixture's construction (DR-26 D8).
  @shared_roles [
    {:certain_adults, 60, :certain, :adult},
    {:certain_children, 4, :certain, :child},
    {:likely_adults, 12, :likely, :adult},
    {:likely_children, 2, :likely, :child}
  ]

  # {role, status, certainty, age} — H1, in the order of task 53's in-memory snapshot.
  @h1_rows [
    {:accepted, :accepted, :certain, :adult},
    {:accepted, :accepted, :likely, :adult},
    {:accepted, :accepted, :uncertain, :adult},
    {:accepted, :accepted, :uncertain, :child},
    {:invited_certain, :invited, :certain, :adult},
    {:invited_certain, :invited, :certain, :adult},
    {:invited_certain, :invited, :certain, :adult},
    {:invited_likely, :invited, :likely, :adult},
    {:invited_likely, :invited, :likely, :child},
    {:planned_uncertain, :planned, :uncertain, :child}
  ]

  @doc """
  Writes the shared Dinner fixture (78 persons, all *invited* to `dinner`) and returns
  them by role. `dinner` is normally `WeddingPlanner.NormativeOfferRows.dinner!/1`.
  Persons are created with `Guests.bulk_create_persons/3` (one batch per role) and
  invited with one `Invitations.bulk_set_invitation_status/4`.
  """
  @spec shared_dinner!(Scope.t(), Event.t()) :: shared()
  def shared_dinner!(%Scope{} = scope, %Event{} = dinner) do
    by_role =
      Map.new(@shared_roles, fn {role, count, certainty, age} ->
        name_maps =
          for n <- 1..count do
            %{first_name: "Shared #{role_label(role)}", last_name: pad(n)}
          end

        {:ok, persons} =
          Guests.bulk_create_persons(scope, name_maps, %{certainty: certainty, age_category: age})

        {role, persons}
      end)

    persons = Enum.flat_map(@shared_roles, fn {role, _, _, _} -> Map.fetch!(by_role, role) end)
    {:ok, invited} = Invitations.bulk_set_invitation_status(scope, persons, dinner, :invited)
    true = length(invited) == length(persons)

    Map.put(by_role, :persons, persons)
  end

  @doc """
  Writes H1's ten persons with their `dinner` invitations (see the moduledoc's table)
  and returns them by role. `plus_one_host` is the accepted, stored-*uncertain* adult.
  """
  @spec h1!(Scope.t(), Event.t()) :: h1()
  def h1!(%Scope{} = scope, %Event{} = dinner) do
    written =
      @h1_rows
      |> Enum.with_index(1)
      |> Enum.map(fn {{role, status, certainty, age}, n} ->
        {:ok, person} =
          Guests.create_person(scope, %{
            first_name: "H1 #{role_label(role)}",
            last_name: pad(n),
            certainty: certainty,
            age_category: age
          })

        {:ok, _invitation} = Invitations.set_invitation_status(scope, person, dinner, status)
        {role, person}
      end)

    by_role =
      Enum.group_by(written, fn {role, _} -> role end, fn {_, person} -> person end)

    %{
      persons: Enum.map(written, fn {_, person} -> person end),
      accepted: Map.fetch!(by_role, :accepted),
      invited_certain: Map.fetch!(by_role, :invited_certain),
      invited_likely: Map.fetch!(by_role, :invited_likely),
      planned_uncertain: Map.fetch!(by_role, :planned_uncertain),
      plus_one_host: Enum.at(Map.fetch!(by_role, :accepted), 2)
    }
  end

  @doc """
  Gives `h1.plus_one_host` an unnamed **adult** +1 with `plus_one_status` (`:confirmed`
  for H2, `:possible` for H3) and no opt-out, through `Guests.add_plus_one/3`. Its want
  tier and certainty are inherited from the host (`DR-32`) and never set here. Returns
  the +1.
  """
  @spec with_plus_one!(Scope.t(), h1(), :confirmed | :possible) :: Person.t()
  def with_plus_one!(%Scope{} = scope, %{plus_one_host: %Person{} = host}, status)
      when status in [:confirmed, :possible] do
    {:ok, plus_one} =
      Guests.add_plus_one(scope, host, %{plus_one_status: status, age_category: :adult})

    plus_one
  end

  @doc """
  H4's person: an adult, stored *certain* (so the only thing keeping them out of any
  preset is the missing invitation), with `want_tier`, and **no invitation at all**.
  Returns the person.
  """
  @spec uninvited!(Scope.t(), Person.want_tier()) :: Person.t()
  def uninvited!(%Scope{} = scope, want_tier) when want_tier in [:yes, :maybe, :no, :obligated] do
    {:ok, person} =
      Guests.create_person(scope, %{
        first_name: "H4 uninvited",
        last_name: Atom.to_string(want_tier),
        want_tier: want_tier,
        certainty: :certain,
        age_category: :adult
      })

    person
  end

  defp role_label(role), do: role |> Atom.to_string() |> String.replace("_", " ")

  defp pad(n), do: n |> Integer.to_string() |> String.pad_leading(2, "0")
end
