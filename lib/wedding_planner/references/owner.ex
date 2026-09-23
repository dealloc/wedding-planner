defmodule WeddingPlanner.References.Owner do
  @moduledoc """
  The attach point between references and whatever owns them (`DR-28`) — the contract
  C2 (offers) and B2 (invoices) implement. `WeddingPlanner.References` knows nothing
  about offers or invoices; every function that touches an owner's references takes one
  of these instead.

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

  Until C2 exists, tests use `%Owner{attrs: %{}, log_entity: {:owner_stub, 1}, name:
  "the test owner"}`. An empty `attrs` map matches **every** row, which is only
  acceptable inside one sandboxed test; it is never a valid production owner.
  """

  @enforce_keys [:attrs, :log_entity, :name]
  defstruct [:attrs, :log_entity, :name]

  @type t :: %__MODULE__{
          attrs: %{optional(atom()) => term()},
          log_entity: {atom() | String.t(), term()},
          name: String.t()
        }
end
