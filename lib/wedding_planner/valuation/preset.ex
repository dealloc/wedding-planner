defmodule WeddingPlanner.Valuation.Preset do
  @moduledoc """
  A **headcount preset** (glossary; `HC-02`) as the valuation engines see it: a name
  plus five criteria, each a set of allowed values where **an empty set means no
  restriction**.

  This is a plain value, not a database row, so that an ad hoc, unsaved filter (`HC-07`)
  and a stored preset are evaluated through exactly the same path. Whatever slice
  persists presets (G4 seeds the three defaults of `HC-06`, G5 adds CRUD) converts each
  stored row into this struct in `WeddingPlanner.Valuation.Snapshot.Loader`, so engines
  only ever see this shape.

  The value atoms are the ones `docs/` names (`PER-02`, `INVT-01`); the persons and
  invitations schemas (G1, G3) are expected to store exactly these values. A preset never
  stores a number (`HC-01`): it is evaluated by
  `WeddingPlanner.Valuation.Headcount.evaluate/3` every time.
  """

  @type invitation_status :: :planned | :invited | :accepted | :declined
  @type certainty :: :certain | :likely | :uncertain
  @type want_tier :: :yes | :maybe | :no | :obligated
  @type age_category :: :adult | :child
  @type role :: :minimum | :likely | :maximum

  @enforce_keys [:name]
  defstruct id: nil,
            name: nil,
            invitation_statuses: MapSet.new(),
            certainties: MapSet.new(),
            want_tiers: MapSet.new(),
            age_categories: MapSet.new(),
            group_ids: MapSet.new(),
            role: nil

  @typedoc """
  `certainties` are *effective* certainties (`HC-04`, `HC-05`), not the stored one.
  `group_ids` holds group ids as the snapshot carries them.

  `id` is `nil` for an ad hoc, unsaved filter (`HC-07`) and the stored row's id for a
  saved preset, so a snapshot's preset collection works with `Snapshot.apply/2` like
  every other collection (`DR-47`).

  `role` identifies which of `DR-54`'s roles this preset plays — `nil` for a plain
  preset (or an ad hoc filter, which never has one) and one of `:minimum`/`:likely`/
  `:maximum` for the single default that fills that slot (`DR-53`).
  """
  @type t :: %__MODULE__{
          id: term() | nil,
          name: String.t(),
          invitation_statuses: MapSet.t(invitation_status()),
          certainties: MapSet.t(certainty()),
          want_tiers: MapSet.t(want_tier()),
          age_categories: MapSet.t(age_category()),
          group_ids: MapSet.t(term()),
          role: role() | nil
        }

  @statuses_counted_by_default MapSet.new([:planned, :invited, :accepted])

  @doc """
  The three default presets `HC-06` says the system ships with (`D-19`), as plain values
  in this order: **Minimum** (effective certainty *certain*), **Likely** (*certain* or
  *likely*) and **Maximum** (any certainty — `HC-02`'s empty set, i.e. no restriction), all
  three over the statuses *planned*, *invited*, *accepted*. Every other criterion is empty.
  Each carries its `DR-53`/`DR-54` role (`:minimum`/`:likely`/`:maximum`) matching its
  name.

  None has an `id`: this is the table itself, not the stored rows. The migration that
  seeds the stored presets inserts exactly these (roles included, set by name), and
  their rows convert back to exactly this list (`DR-47`, `DR-53`).
  """
  @spec defaults() :: [t()]
  def defaults do
    [
      %__MODULE__{
        name: "Minimum",
        invitation_statuses: @statuses_counted_by_default,
        certainties: MapSet.new([:certain]),
        role: :minimum
      },
      %__MODULE__{
        name: "Likely",
        invitation_statuses: @statuses_counted_by_default,
        certainties: MapSet.new([:certain, :likely]),
        role: :likely
      },
      %__MODULE__{
        name: "Maximum",
        invitation_statuses: @statuses_counted_by_default,
        certainties: MapSet.new(),
        role: :maximum
      }
    ]
  end
end
