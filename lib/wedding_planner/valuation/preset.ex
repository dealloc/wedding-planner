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

  @enforce_keys [:name]
  defstruct name: nil,
            invitation_statuses: MapSet.new(),
            certainties: MapSet.new(),
            want_tiers: MapSet.new(),
            age_categories: MapSet.new(),
            group_ids: MapSet.new()

  @typedoc """
  `certainties` are *effective* certainties (`HC-04`, `HC-05`), not the stored one.
  `group_ids` holds group ids as the snapshot carries them.
  """
  @type t :: %__MODULE__{
          name: String.t(),
          invitation_statuses: MapSet.t(invitation_status()),
          certainties: MapSet.t(certainty()),
          want_tiers: MapSet.t(want_tier()),
          age_categories: MapSet.t(age_category()),
          group_ids: MapSet.t(term())
        }
end
