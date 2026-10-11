defmodule WeddingPlanner.Valuation.Snapshot.Loader do
  @moduledoc """
  The implementation of `WeddingPlanner.Valuation.Snapshot.load/1`, and **the only module
  in `WeddingPlanner.Valuation` allowed to query the database**
  (`WeddingPlanner.Valuation.PurityTest` fails the build otherwise).

  ## The query budget (`NFR-33`)

  **One query per collection**, plus one for the settings singleton, and never a query
  per row. Every collection is read whole with a plain `repo.all/1`; relations are
  resolved by id in memory (see `WeddingPlanner.Valuation.Snapshot`), so there are no
  preloads and no follow-up queries. No money is aggregated in SQL (`NFR-13`): amounts
  arrive as stored `%Money{}` values and are only ever combined in Elixir.

  All queries run inside one read transaction, so the snapshot is one consistent view
  of the database: a row deleted between two of the reads (an event, say, and then the
  offer lines pointing at it) cannot leave the snapshot half-before and half-after.

  ## Adding a collection — the one place each later slice touches

  Add a single entry to the struct built in `load/1` below, e.g. for G1:

      persons: repo.all(from p in Person, order_by: [asc: p.id]),

  and narrow the field's type in `WeddingPlanner.Valuation.Snapshot`. Keep it one query:
  if an engine needs a related row, it looks it up in that row's own collection rather
  than preloading it here. A slice whose stored shape differs from what engines consume
  converts it here — G4 turns the seeded `headcount_presets` rows into
  `WeddingPlanner.Valuation.Preset` values through
  `WeddingPlanner.Presets.HeadcountPreset.to_preset/1`; G5 adds the rest of the CRUD.
  Then add the new table to the expected sources in
  `WeddingPlanner.Valuation.SnapshotLoadTest`.
  """

  import Ecto.Query

  alias WeddingPlanner.Categories.Category
  alias WeddingPlanner.Categories.Service
  alias WeddingPlanner.Events.Event
  alias WeddingPlanner.Guests.{Group, Person}
  alias WeddingPlanner.Invitations.Invitation
  alias WeddingPlanner.Invitations.PlusOneOptOut
  alias WeddingPlanner.Invoices.Invoice
  alias WeddingPlanner.Invoices.InvoiceLine
  alias WeddingPlanner.Offers.FrozenService
  alias WeddingPlanner.Offers.Offer
  alias WeddingPlanner.Offers.OfferLine
  alias WeddingPlanner.Offers.Override
  alias WeddingPlanner.Presets.HeadcountPreset
  alias WeddingPlanner.Seating.{Circle, CircleMembership, Pin, Rule, Table}
  alias WeddingPlanner.Settings
  alias WeddingPlanner.Valuation.Snapshot

  @doc "See `WeddingPlanner.Valuation.Snapshot.load/1`."
  @spec load(module()) :: Snapshot.t()
  def load(repo) do
    {:ok, snapshot} =
      repo.transaction(fn ->
        %Snapshot{
          settings: settings(repo),
          # EVT-04: manual sort order, `id` as the stable tiebreak — the same order
          # `WeddingPlanner.Events.list_events/0` returns (SnapshotLoadTest pins that).
          events: repo.all(from e in Event, order_by: [asc: e.sort_order, asc: e.id]),
          persons: repo.all(from p in Person, order_by: [asc: p.id]),
          groups: repo.all(from g in Group, order_by: [asc: g.id]),
          # CST-01/`Budget.forecast/2`'s contract: the categories' own sort order, `id`
          # as the stable tiebreak — the same order `Categories.list_categories/0`
          # returns.
          categories: repo.all(from c in Category, order_by: [asc: c.sort_order, asc: c.id]),
          # CST-02: each category's services in their own sort order, grouped by
          # category first so a consumer can chunk by `category_id` without re-sorting.
          services:
            repo.all(
              from s in Service,
                order_by: [asc: s.category_id, asc: s.sort_order, asc: s.id]
            ),
          offers: repo.all(from o in Offer, order_by: [asc: o.id]),
          offer_lines: repo.all(from l in OfferLine, order_by: [asc: l.id]),
          invitations: repo.all(from i in Invitation, order_by: [asc: i.id]),
          plus_one_opt_outs: repo.all(from o in PlusOneOptOut, order_by: [asc: o.id]),
          headcount_presets:
            repo.all(from p in HeadcountPreset, order_by: [asc: p.sort_order, asc: p.id])
            |> Enum.map(&HeadcountPreset.to_preset/1),
          # DR-56: at most one row per offer × service (the unique index), read whole —
          # `Valuation.Selection.effectively_wanted?/3` resolves the pair in memory.
          overrides: repo.all(from o in Override, order_by: [asc: o.id]),
          # DR-61: every frozen row, read whole — `Valuation.Selection` answers from them
          # for a confirmed offer and ignores them for any other.
          frozen_services: repo.all(from f in FrozenService, order_by: [asc: f.id]),
          invoices: repo.all(from i in Invoice, order_by: [asc: i.id]),
          invoice_lines: repo.all(from l in InvoiceLine, order_by: [asc: l.id]),
          circles: repo.all(from c in Circle, order_by: [asc: c.id]),
          circle_memberships: repo.all(from m in CircleMembership, order_by: [asc: m.id]),
          seating_rules: repo.all(from r in Rule, order_by: [asc: r.id]),
          # SEAT-40: each event's tables in their own sort order, grouped by event.
          seating_tables:
            repo.all(from t in Table, order_by: [asc: t.event_id, asc: t.sort_order, asc: t.id]),
          seating_pins: repo.all(from p in Pin, order_by: [asc: p.id])
        }
      end)

    snapshot
  end

  # The singleton row is created on first access by `WeddingPlanner.Settings.get/0`,
  # which writes. A snapshot load only reads, so if the row has never been created the
  # snapshot carries an unsaved default instead: overall budget unset (`BUD-01`), which
  # is exactly what that row would say once created.
  defp settings(repo), do: repo.one(Settings) || %Settings{}
end
