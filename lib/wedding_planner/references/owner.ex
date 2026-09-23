defmodule WeddingPlanner.References.Owner do
  @moduledoc """
  The attach point between references and whatever owns them (`DR-28`) — the contract
  C2 (offers, `WeddingPlanner.Offers.reference_owner/1`) and B2 (invoices,
  `WeddingPlanner.Invoices.reference_owner/1`) implement. `WeddingPlanner.References`
  knows nothing about offers or invoices; every function that touches an owner's
  references takes one of these instead.

      %Owner{
        attrs: %{offer_id: offer.id},
        log_entity: {:offer, offer.id},
        name: "offer '\#{offer.name}'"
      }

  ## Fields

    * `attrs` — a map of owner foreign-key columns to values. It is **put on every new
      row** (`struct!/2`, so a key the schema does not know raises instead of silently
      creating an ownerless row) **and used as the where-clause** for listing, the
      ownership check on update/delete, the XC-24 cascade and the deletion-effects count.
      In production it MUST name exactly the owner's FK — `%{offer_id: id}` or
      `%{invoice_id: id}` — and the column plus its `belongs_to` on
      `WeddingPlanner.References.Reference` must exist first (C2/B2 add them).
    * `log_entity` — the `{type, id}` activity entries are written against. It is the
      **owner**, not the reference: references have no page and no `EntityRef` type, and
      writing against the owner is what makes an offer's own history (`XC-11`) show its
      attachments.
    * `name` — how the owner reads in a sentence, used in log wording and confirmation
      text: "Wannes attached 'Quote' (PDF) to **offer 'Venue A'**".

  ## The test stand-in

  Now that C2 (offers) exists, `WeddingPlanner.ReferenceFixtures.owner/0` builds a real
  owner from a freshly inserted offer (`WeddingPlanner.Offers.reference_owner/1`) rather
  than a fabricated struct with no backing row — every reference a test creates through
  it satisfies `references_exactly_one_owner` (`DR-28`) like any production row. A
  **deliberately wrong** owner (an `attrs` naming a column no row will ever match, e.g.
  `%{id: -1}`) is still used directly in a handful of tests to exercise refusal paths
  (`{:error, :not_owned}`, a `KeyError` for an unknown attrs key) — those are not stand-ins
  for a missing slice, just fixtures for a negative case.
  """

  @enforce_keys [:attrs, :log_entity, :name]
  defstruct [:attrs, :log_entity, :name]

  @type t :: %__MODULE__{
          attrs: %{optional(atom()) => term()},
          log_entity: {atom() | String.t(), term()},
          name: String.t()
        }
end
