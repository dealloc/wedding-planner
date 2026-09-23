defmodule WeddingPlanner.Valuation.Snapshot do
  @moduledoc """
  The whole planning state, loaded once and then only read (`NFR-13`, `NFR-33`,
  `NFR-41`, `BUD-21`). Every valuation engine is a pure function over one of these.

  ## One flat collection per entity

  Every planning entity of `docs/03-domain-model.md` that can influence a computed
  number has exactly one field here, holding **every row of that entity** as a flat
  list. Relations are resolved **by id** against these collections (an invitation's
  `person_id` against `persons`, an offer line's `event_id` against `events`, …), never
  through Ecto association fields, which the loader deliberately leaves unloaded.

  The reason is `apply/2`: with each fact held in exactly one place, a what-if change
  replaces one element of one list and cannot leave a second, nested copy of the same row
  disagreeing with it. It also means there is nothing left to load lazily: every row an
  engine can reach is already in memory.

  | Field               | Entity                          | Owning slice          | Today             |
  |---------------------|---------------------------------|-----------------------|-------------------|
  | `settings`          | Settings (singleton)            | F0.6 (task 21)        | loaded            |
  | `events`            | Event                           | F0.6 (task 22)        | loaded, `EVT-04` order |
  | `persons`           | Person (incl. +1s)              | G1, G2                | loaded, incl. `host_id`/`plus_one_status` (`DR-32`) |
  | `groups`            | Group                           | G1                    | loaded            |
  | `plus_one_opt_outs` | Plus-one opt-out                | G3                    | loaded            |
  | `invitations`       | Invitation                      | G3                    | loaded            |
  | `headcount_presets` | Headcount preset (as `WeddingPlanner.Valuation.Preset`) | G4, G5 | `[]`       |
  | `categories`        | Category                        | C1                    | loaded, `CST-01` order |
  | `services`          | Service                         | C1                    | loaded, per-category order |
  | `offers`            | Offer                           | C2                    | loaded            |
  | `offer_lines`       | Offer line                      | C2                    | loaded, invalid (event deleted) lines included |
  | `overrides`         | Override                        | C4 (persists and toggles) | `[]` — C3's `Valuation.Selection` reads rows with `offer_id`, `service_id`, `wanted` (`DR-49`) |
  | `invoices`          | Invoice                         | B2                    | `[]`              |
  | `invoice_lines`     | Invoice line                    | B2                    | `[]`              |

  Users, passkeys, enrollment links and activity entries are not planning state. Tasks
  and references are planning entities but no rule in `docs/` lets either influence a
  headcount, an offer total or a budget layer, so they are not loaded; add a field here
  if that ever changes.

  **How a later slice extends this:** narrow the field's type below from `[struct()]` to
  its schema's `t()`, and add its one query in
  `WeddingPlanner.Valuation.Snapshot.Loader` (the only place, see that module). Nothing
  else changes: the field already exists, `apply/2` already handles it, and every engine
  already receives it.

  ## Loading

  `load/1` is the only function in `WeddingPlanner.Valuation` that touches the
  database, and it only reads. It delegates to
  `WeddingPlanner.Valuation.Snapshot.Loader`; see there for the query budget.

  A snapshot can equally be built in memory (`%Snapshot{events: [...]}`), which is what
  pure engine tests do: no Ecto, no sandbox.

  ## What-if (`BUD-20`, `BUD-21`, `BUD-22`)

  `apply/2` returns a modified copy and never touches the database. A what-if is
  evaluated as the same engine over the original snapshot and over
  `apply(snapshot, change)`, and the delta is the difference of the two full results,
  never a sum of per-person rates. See `t:change/0` for the change representation.
  """

  import Kernel, except: [apply: 2]

  alias WeddingPlanner.Categories.Category
  alias WeddingPlanner.Categories.Service
  alias WeddingPlanner.Events.Event
  alias WeddingPlanner.Guests.Group
  alias WeddingPlanner.Guests.Person
  alias WeddingPlanner.Invitations.Invitation
  alias WeddingPlanner.Invitations.PlusOneOptOut
  alias WeddingPlanner.Offers.Offer
  alias WeddingPlanner.Offers.OfferLine
  alias WeddingPlanner.Settings
  alias WeddingPlanner.Valuation.Preset
  alias WeddingPlanner.Valuation.Snapshot.Loader

  @collections [
    :events,
    :persons,
    :groups,
    :plus_one_opt_outs,
    :invitations,
    :headcount_presets,
    :categories,
    :services,
    :offers,
    :offer_lines,
    :overrides,
    :invoices,
    :invoice_lines
  ]

  defstruct [settings: %Settings{}] ++ Enum.map(@collections, &{&1, []})

  @typedoc """
  Fields typed `[struct()]` hold entities whose schemas do not exist yet; the owning
  slice narrows the type when it adds its schema (see the moduledoc's table).
  """
  @type t :: %__MODULE__{
          settings: Settings.t(),
          events: [Event.t()],
          persons: [Person.t()],
          groups: [Group.t()],
          plus_one_opt_outs: [PlusOneOptOut.t()],
          invitations: [Invitation.t()],
          headcount_presets: [Preset.t()],
          categories: [Category.t()],
          services: [Service.t()],
          offers: [Offer.t()],
          offer_lines: [OfferLine.t()],
          overrides: [struct()],
          invoices: [struct()],
          invoice_lines: [struct()]
        }

  @typedoc "The name of one of the snapshot's entity collections (every field but `settings`)."
  @type collection ::
          :events
          | :persons
          | :groups
          | :plus_one_opt_outs
          | :invitations
          | :headcount_presets
          | :categories
          | :services
          | :offers
          | :offer_lines
          | :overrides
          | :invoices
          | :invoice_lines

  @typedoc """
  A hypothetical change to the planning state, for `apply/2`.

    * `{:put, collection, entity}` — inserts `entity` into `collection`, or replaces the
      element with the same `id` **in place** (its position is kept). `entity` must be a
      struct with a non-`nil` `:id`.
    * `{:delete, collection, id}` — removes the element with that `id`. Raises if there
      is none: a what-if that deletes something absent is a bug in the caller.
    * a list of changes — applied in order, each to the result of the previous one.

  That is enough for every what-if `docs/` asks for: inviting persons who are not counted
  yet is a `:put` of each person plus their invitations; changing a status is a `:put` of
  the updated invitation; a person's marginal cost (`BUD-22`) is the list of `:delete`s
  of the person, their +1s and all of their invitations and opt-outs.

  Rules the caller is responsible for, because `apply/2` knows nothing about any entity:

    * **No cascades.** Deleting a row does not delete rows that reference it; the change
      must name every row to remove.
    * **No reordering.** `:put` never moves an element, so a change to a manual sort
      order is not something a what-if can express (none in `docs/` needs it).
    * **Hypothetical rows need unique ids.** A row that does not exist in the database
      must carry an id no loaded row has; use `make_ref/0`. Engines compare ids with
      `==` and never assume they are integers.
  """
  @type change ::
          {:put, collection(), struct()}
          | {:delete, collection(), term()}
          | [change()]

  @doc """
  Loads the whole planning state through `repo`, read-only, in a bounded number of
  queries that does not grow with the number of rows (`NFR-33`). See
  `WeddingPlanner.Valuation.Snapshot.Loader`.
  """
  @spec load(module()) :: t()
  def load(repo), do: Loader.load(repo)

  @doc """
  Returns `snapshot` with `change` applied (see `t:change/0`). Pure: it never reads or
  writes the database and never modifies `snapshot` itself.
  """
  @spec apply(t(), change()) :: t()
  def apply(%__MODULE__{} = snapshot, changes) when is_list(changes) do
    Enum.reduce(changes, snapshot, fn change, acc -> apply(acc, change) end)
  end

  def apply(%__MODULE__{} = snapshot, {:put, collection, entity}) do
    id = entity_id!(entity)

    update_collection(snapshot, collection, fn rows ->
      case Enum.find_index(rows, &(&1.id == id)) do
        nil -> rows ++ [entity]
        index -> List.replace_at(rows, index, entity)
      end
    end)
  end

  def apply(%__MODULE__{} = snapshot, {:delete, collection, id}) do
    update_collection(snapshot, collection, fn rows ->
      case Enum.split_with(rows, &(&1.id == id)) do
        {[], _rows} ->
          raise ArgumentError,
                "cannot delete #{inspect(id)} from #{inspect(collection)}: no such row"

        {_deleted, kept} ->
          kept
      end
    end)
  end

  def apply(%__MODULE__{}, change) do
    raise ArgumentError, "not a snapshot change: #{inspect(change)}"
  end

  defp update_collection(snapshot, collection, fun) when collection in @collections do
    Map.update!(snapshot, collection, fun)
  end

  defp update_collection(_snapshot, collection, _fun) do
    raise ArgumentError,
          "#{inspect(collection)} is not a snapshot collection; expected one of " <>
            inspect(@collections)
  end

  defp entity_id!(%_{id: id}) when not is_nil(id), do: id

  defp entity_id!(entity) do
    raise ArgumentError,
          "a snapshot change needs a struct with a non-nil :id, got: #{inspect(entity)}"
  end
end
