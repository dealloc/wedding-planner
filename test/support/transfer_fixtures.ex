defmodule WeddingPlanner.TransferFixtures do
  @moduledoc """
  Test support for the data transfer (`DR-93`, `DR-96`): one rich data set that puts at
  least one row in **every** transferred table (`WeddingPlanner.Transfer.Tables`) and
  exercises every field type the codec carries, so an export → import → export round trip
  over it covers everything. Reused by tasks 98, 100 and 101 (they may append helpers).

  Everything is built through the **contexts** (`Settings`, `Guests`, `Invitations`,
  `Presets`, `Categories`, `Offers`, `Invoices`, `References`, `Tasks`), so the rows and
  their activity entries are the real ones. The exceptions, each because no context
  creates the row: the `demo_seed_runs` marker (`Repo.insert!/1`, `DR-79`), and the second
  user and her passkey (inserted the way the other test modules do, since only a WebAuthn
  ceremony creates them in production).

  `rich!/1` writes one PDF into the test `:uploads_dir` (a file reference) and calls
  `WeddingPlanner.ReferenceFixtures.track_uploads_dir/0` first, so the file is removed when
  the calling test exits. Call it from a test or its `setup`.

  What it builds:

    * settings with an overall budget of € 45.000;
    * 2 groups; 3 events ("Ceremony", "Dinner", "Brunch"; Brunch has no date);
    * persons, incl. "Zoë Dupré", a named +1 ("Tom Wils") and an unnamed +1, the named one
      opted out of Brunch;
    * invitations in all four statuses, the "invited" ones set by one bulk action (a
      summarising activity entry with children);
    * a custom headcount preset with `group_ids` and non-empty criteria;
    * 2 categories ("Venue" with a target, "Catering" without) and their services;
    * a VAT-exclusive catering offer with: a per-adult line with its own `vat_rate_bp`, an
      optional ad-hoc line toggled on, a line whose amount was **cleared** after creation
      (stored as the text `'null'`, `DR-45`), a line of exactly
      `Decimal.new("7641.4999999999999999")` (typed `%Money{}`, `DR-46`), an override, and
      the planning pick of its category;
    * a **confirmed** venue offer (so frozen services exist);
    * an invoice linked to the confirmed offer with 2 lines, paid, and an unpaid one;
    * a file reference (`ReferenceFixtures.bytes(:pdf)`) and a URL reference;
    * tasks: owned by the second user, shared, with a relative deadline, linked to an
      offer, and a dependency between two of them;
    * one `demo_seed_runs` row;
    * a second user ("Lotte") with a passkey named `"SECRET-PASSKEY"`, who owns a task.
  """

  import WeddingPlanner.OfferFixtures, only: [scope_fixture: 0]

  alias WeddingPlanner.Accounts.Passkey
  alias WeddingPlanner.Accounts.Scope
  alias WeddingPlanner.Accounts.User
  alias WeddingPlanner.Categories
  alias WeddingPlanner.DemoSeedRun
  alias WeddingPlanner.Events
  alias WeddingPlanner.Guests
  alias WeddingPlanner.Invitations
  alias WeddingPlanner.Invoices
  alias WeddingPlanner.Offers
  alias WeddingPlanner.Presets
  alias WeddingPlanner.ReferenceFixtures
  alias WeddingPlanner.References
  alias WeddingPlanner.Repo
  alias WeddingPlanner.Settings
  alias WeddingPlanner.Tasks

  @doc "The passkey name `rich!/1` gives the second user's passkey (must never be exported)."
  def secret_passkey_name, do: "SECRET-PASSKEY"

  @doc "The high-precision line amount `rich!/1` stores, as its exact decimal string."
  def precise_amount, do: "7641.4999999999999999"

  @doc """
  Builds the rich data set (see the moduledoc) as `scope`'s user (a fresh "Wannes" when
  `nil`). Returns a map of what it built, keyed by name.
  """
  @spec rich!(Scope.t() | nil) :: map()
  def rich!(scope \\ nil) do
    scope = scope || scope_fixture()
    ReferenceFixtures.track_uploads_dir()

    lotte = %User{} |> User.changeset(%{display_name: "Lotte"}) |> Repo.insert!()
    passkey = insert_passkey!(lotte, secret_passkey_name())

    {:ok, settings} =
      Settings.update(scope, Settings.get(), %{"overall_budget_input" => "45000"})

    {:ok, family} =
      Guests.create_group(scope, %{"name" => "Family Peeters", "type_label" => "Family"})

    {:ok, friends} = Guests.create_group(scope, %{"name" => "Friends"})

    {:ok, ceremony} =
      Events.create_event(scope, %{
        "name" => "Ceremony",
        "date" => ~D[2027-06-12],
        "location" => "Town hall"
      })

    {:ok, dinner} = Events.create_event(scope, %{"name" => "Dinner", "date" => ~D[2027-06-12]})

    {:ok, brunch} =
      Events.create_event(scope, %{"name" => "Brunch", "notes" => "Date to be decided"})

    {:ok, anna} =
      Guests.create_person(scope, %{
        "first_name" => "Anna",
        "last_name" => "Peeters",
        "group_id" => family.id,
        "want_tier" => "obligated",
        "certainty" => "certain"
      })

    {:ok, zoe} =
      Guests.create_person(scope, %{
        "first_name" => "Zoë",
        "last_name" => "Dupré",
        "group_id" => friends.id,
        "age_category" => "adult",
        "notes" => "Vegetarian — no fish"
      })

    {:ok, bram} =
      Guests.create_person(scope, %{
        "first_name" => "Bram",
        "last_name" => "Peeters",
        "group_id" => family.id,
        "age_category" => "child",
        "want_tier" => "maybe",
        "certainty" => "uncertain"
      })

    {:ok, named_plus_one} =
      Guests.add_plus_one(scope, anna, %{
        "first_name" => "Tom",
        "last_name" => "Wils",
        "plus_one_status" => "confirmed"
      })

    {:ok, unnamed_plus_one} = Guests.add_plus_one(scope, zoe, %{})

    {:ok, _} = Invitations.set_invitation_status(scope, anna, ceremony, :accepted)
    {:ok, _} = Invitations.set_invitation_status(scope, zoe, dinner, :declined)
    {:ok, _} = Invitations.set_invitation_status(scope, bram, ceremony, :planned)
    {:ok, _} = Invitations.set_invitation_status(scope, anna, brunch, :accepted)
    {:ok, [_ | _]} = Invitations.bulk_set_invitation_status(scope, [anna, bram], dinner, :invited)
    {:ok, opt_out} = Invitations.set_opt_out(scope, named_plus_one, brunch, true)

    {:ok, preset} =
      Presets.create_preset(scope, %{
        "name" => "Family, certain",
        "invitation_statuses" => ["invited", "accepted"],
        "certainties" => ["certain", "likely"],
        "want_tiers" => ["yes", "obligated"],
        "age_categories" => ["adult"],
        "group_ids" => [family.id, friends.id]
      })

    {:ok, venue} =
      Categories.create_category(scope, %{"name" => "Venue", "target_input" => "15000"})

    {:ok, catering} = Categories.create_category(scope, %{"name" => "Catering"})

    {:ok, hall} =
      Categories.create_service(scope, venue, %{
        "name" => "Hall",
        "wanted_priority" => "must_have"
      })

    {:ok, _garden} =
      Categories.create_service(scope, venue, %{
        "name" => "Garden",
        "wanted_priority" => "not_wanted"
      })

    {:ok, food} =
      Categories.create_service(scope, catering, %{
        "name" => "Food",
        "wanted_priority" => "must_have"
      })

    {:ok, drinks} =
      Categories.create_service(scope, catering, %{
        "name" => "Drinks",
        "wanted_priority" => "nice_to_have"
      })

    # -- the VAT-exclusive catering offer (planning pick) --------------------------------
    {:ok, catering_offer} =
      Offers.create_offer(scope, catering, %{
        "vendor_name" => "Traiteur Dupré",
        "url" => "https://example.com/traiteur",
        "vat_basis" => "exclusive",
        "vat_rate_input" => "21",
        "minimum_spend_input" => "2500"
      })

    {:ok, food_line} =
      Offers.create_line(scope, catering_offer, %{
        "service_id" => food.id,
        "state" => "mandatory",
        "basis" => "per_adult",
        "event_id" => dinner.id,
        "amount_input" => "85",
        "included_quantity" => "10",
        "minimum_charge_input" => "1500",
        "vat_rate_bp" => 600
      })

    {:ok, bar_line} =
      Offers.create_line(scope, catering_offer, %{
        "label" => "Cocktail bar",
        "state" => "optional",
        "basis" => "flat",
        "amount_input" => "350"
      })

    {:ok, bar_line} = Offers.set_line_enabled(scope, bar_line, true)

    {:ok, cleared_line} =
      Offers.create_line(scope, catering_offer, %{
        "service_id" => drinks.id,
        "state" => "optional",
        "basis" => "flat",
        "amount_input" => "120"
      })

    # Priced → unpriced clears the amount on UPDATE: stored as the text 'null' (DR-45).
    {:ok, cleared_line} = Offers.update_line(scope, cleared_line, %{"state" => "included"})

    {:ok, precise_line} =
      Offers.create_line(scope, catering_offer, %{
        "label" => "Service fee",
        "state" => "mandatory",
        "basis" => "flat",
        "amount" => WeddingPlanner.Money.new(Decimal.new(precise_amount()))
      })

    {:ok, _} = Offers.toggle_override(scope, catering_offer, drinks)
    {:ok, catering_offer} = Offers.set_planning_pick(scope, catering_offer)

    # -- the confirmed venue offer -------------------------------------------------------
    {:ok, venue_offer} =
      Offers.create_offer(scope, venue, %{
        "vendor_name" => "Kasteel Heers",
        "notes" => "Incl. VAT"
      })

    {:ok, _hall_line} =
      Offers.create_line(scope, venue_offer, %{
        "service_id" => hall.id,
        "state" => "mandatory",
        "basis" => "flat",
        "amount_input" => "9000"
      })

    {:ok, venue_offer} = Offers.confirm_offer(scope, venue_offer)

    # -- invoices ------------------------------------------------------------------------
    {:ok, paid_invoice} =
      Invoices.create_invoice(
        scope,
        venue,
        %{
          "label" => "Venue deposit",
          "invoice_date" => ~D[2027-01-01],
          "due_date" => ~D[2027-01-31],
          "offer_id" => venue_offer.id
        },
        %{"label" => "Deposit", "amount_input" => "3000"}
      )

    {:ok, _} =
      Invoices.create_line(scope, paid_invoice, %{
        "label" => "Cleaning",
        "amount_input" => "250,50"
      })

    {:ok, paid_invoice} = Invoices.mark_paid(scope, paid_invoice, ~D[2027-01-15])

    {:ok, unpaid_invoice} =
      Invoices.create_invoice(
        scope,
        catering,
        %{"label" => "Tasting", "invoice_date" => ~D[2027-02-01]},
        %{"label" => "Tasting menu", "amount_input" => "120"}
      )

    # -- references ----------------------------------------------------------------------
    source_dir = ReferenceFixtures.tmp_upload_dir!()

    {:ok, file_reference} =
      References.create_file_reference(
        scope,
        Offers.reference_owner(venue_offer),
        %{"label" => "Signed quote"},
        ReferenceFixtures.write_fixture!(source_dir, :pdf, "quote.pdf")
      )

    {:ok, url_reference} =
      References.create_url_reference(scope, Invoices.reference_owner(paid_invoice), %{
        "label" => "Payment portal",
        "url" => "https://example.com/pay"
      })

    # -- tasks ---------------------------------------------------------------------------
    {:ok, owned_task} =
      Tasks.create_task(scope, %{
        "title" => "Book the florist",
        "owner_id" => lotte.id,
        "status" => "in_progress",
        "deadline_kind" => "fixed",
        "deadline_date" => ~D[2027-03-01]
      })

    {:ok, shared_task} =
      Tasks.create_task(scope, %{
        "title" => "Send invitations",
        "owner_shared" => true,
        "notes" => "Both of us",
        "deadline_kind" => "relative",
        "deadline_amount" => "2",
        "deadline_unit" => "weeks",
        "deadline_direction" => "before",
        "deadline_event_id" => dinner.id
      })

    {:ok, linked_task} =
      Tasks.create_task(scope, %{
        "title" => "Confirm the menu",
        "link_offer_id" => catering_offer.id
      })

    {:ok, dependency} = Tasks.add_dependency(scope, shared_task, owned_task)

    demo_seed_run = Repo.insert!(%DemoSeedRun{name: "transfer-fixture"})

    %{
      scope: scope,
      lotte: lotte,
      passkey: passkey,
      settings: settings,
      groups: [family, friends],
      events: %{ceremony: ceremony, dinner: dinner, brunch: brunch},
      persons: %{
        anna: anna,
        zoe: zoe,
        bram: bram,
        named_plus_one: named_plus_one,
        unnamed_plus_one: unnamed_plus_one
      },
      opt_out: opt_out,
      preset: preset,
      categories: %{venue: venue, catering: catering},
      services: %{hall: hall, food: food, drinks: drinks},
      offers: %{catering: catering_offer, venue: venue_offer},
      lines: %{food: food_line, bar: bar_line, cleared: cleared_line, precise: precise_line},
      invoices: %{paid: paid_invoice, unpaid: unpaid_invoice},
      references: %{file: file_reference, url: url_reference},
      tasks: %{owned: owned_task, shared: shared_task, linked: linked_task},
      dependency: dependency,
      demo_seed_run: demo_seed_run
    }
  end

  defp insert_passkey!(user, name) do
    %Passkey{user_id: user.id, sign_count: 0}
    |> Passkey.registration_changeset(%{
      credential_id: :crypto.strong_rand_bytes(16),
      public_key: Passkey.encode_cose_key(%{1 => 2, 3 => -7, -1 => 1, -2 => <<1, 2, 3>>}),
      name: name,
      registered_at: DateTime.utc_now(:second)
    })
    |> Repo.insert!()
  end
end
