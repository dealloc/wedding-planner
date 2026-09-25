defmodule WeddingPlanner.Transfer.Tables do
  @moduledoc """
  The data-transfer registry (`DR-93`, `DR-96`): which tables travel in an export, in
  which order, which are excluded and why, and which fields point at a user.

  ## Transferred (`DR-93` (1))

  `transferred/0` lists the 19 domain tables plus the `DR-79` bookkeeping table
  `demo_seed_runs` (so `mix ecto.setup` classifies an imported database the way it
  classified the source: a demo export stays a demo database). The order is
  **parents first**: the applier inserts in this order and deletes in reverse. Each entry's
  `key` is the schema's own table name (`__schema__(:source)`), so no table name is written
  by hand here. `label` is the English plural shown in the import preview; `preview?` is
  false only for `demo_seed_runs`, which is still transferred but never shown.

  ## Excluded (`DR-93` (2))

  `excluded/0` names every other SQLite table with a one-line reason. A tripwire test
  asserts that transferred ∪ excluded is exactly the set of tables in the database, so a
  table added by a future migration fails the suite until it is placed on one side
  (`DR-96` (i)).

  ## User references (`DR-93` (2))

  `user_references/0` lists every field of a transferred schema that points at
  `WeddingPlanner.Accounts.User`. Users do not travel (only an id + display-name remap
  list does), so these fields are remapped on import. A tripwire test asserts the list
  equals every `belongs_to … User` found in a transferred schema (`DR-96` (iv)).
  """

  alias WeddingPlanner.Categories.Category
  alias WeddingPlanner.Categories.Service
  alias WeddingPlanner.DemoSeedRun
  alias WeddingPlanner.Events.Event
  alias WeddingPlanner.Guests.Group
  alias WeddingPlanner.Guests.Person
  alias WeddingPlanner.Invitations.Invitation
  alias WeddingPlanner.Invitations.PlusOneOptOut
  alias WeddingPlanner.Invoices.Invoice
  alias WeddingPlanner.Invoices.InvoiceLine
  alias WeddingPlanner.Log.Entry
  alias WeddingPlanner.Offers.FrozenService
  alias WeddingPlanner.Offers.Offer
  alias WeddingPlanner.Offers.OfferLine
  alias WeddingPlanner.Offers.Override
  alias WeddingPlanner.Presets.HeadcountPreset
  alias WeddingPlanner.References.Reference
  alias WeddingPlanner.Settings
  alias WeddingPlanner.Tasks.Dependency
  alias WeddingPlanner.Tasks.Task

  @type entry :: %{key: String.t(), schema: module(), label: String.t(), preview?: boolean()}

  # Parents first (DR-93 (3), DR-98): the applier inserts in this order, deletes in reverse.
  @registry [
    {Settings, "Settings", true},
    {Group, "Groups", true},
    {Event, "Events", true},
    {Person, "People", true},
    {Invitation, "Invitations", true},
    {PlusOneOptOut, "+1 opt-outs", true},
    {HeadcountPreset, "Headcount presets", true},
    {Category, "Categories", true},
    {Service, "Services", true},
    {Offer, "Offers", true},
    {OfferLine, "Offer lines", true},
    {Override, "Offer overrides", true},
    {FrozenService, "Frozen services", true},
    {Invoice, "Invoices", true},
    {InvoiceLine, "Invoice lines", true},
    {Reference, "References", true},
    {Task, "Tasks", true},
    {Dependency, "Task dependencies", true},
    {Entry, "Activity entries", true},
    {DemoSeedRun, "Demo-data markers", false}
  ]

  @excluded [
    %{
      table: "users",
      reason:
        "user accounts stay with each installation; exported only as the id + display-name remap list (DR-93)"
    },
    %{table: "passkeys", reason: "bound to the host (WebAuthn rp_id), so useless elsewhere"},
    %{table: "user_sessions", reason: "sign-in sessions belong to this installation"},
    %{table: "enrollment_links", reason: "device enrollment links belong to this installation"},
    %{table: "schema_migrations", reason: "Ecto's migration bookkeeping, not data"},
    %{table: "money_probes", reason: "NFR-10 storage probe, not domain data"}
  ]

  @user_references [{Task, :owner_id}, {Entry, :user_id}]

  @doc """
  The transferred tables, parents first (see the moduledoc). `key` is
  `schema.__schema__(:source)`.
  """
  @spec transferred() :: [entry()]
  def transferred do
    for {schema, label, preview?} <- @registry do
      %{key: schema.__schema__(:source), schema: schema, label: label, preview?: preview?}
    end
  end

  @doc "The tables that never travel, each with a one-line reason (`DR-93` (2))."
  @spec excluded() :: [%{table: String.t(), reason: String.t()}]
  def excluded, do: @excluded

  @doc """
  Every `{schema, field}` of a transferred schema that references a user
  (`tasks.owner_id`, `activity_entries.user_id`); remapped on import (`DR-93` (2)).
  """
  @spec user_references() :: [{module(), atom()}]
  def user_references, do: @user_references
end
