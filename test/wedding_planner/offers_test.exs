defmodule WeddingPlanner.OffersTest do
  @moduledoc """
  `docs/modules/offers-and-comparison.md` `CST-10`, `CST-33`, `CST-36`, `CST-40`,
  `CST-42`; `docs/04-cross-cutting.md` `XC-01`, `XC-10`–`XC-12`, `XC-20`–`XC-24`;
  `DR-18`, `DR-23`, `DR-26` Q11, `DR-28`, `DR-40` — slice C2's offers data layer.

  `async: false`: the reference-deletion tests diff `:uploads_dir`, same reason
  `WeddingPlanner.ReferencesTest` is `async: false`.
  """
  use WeddingPlanner.DataCase, async: false

  import WeddingPlanner.OfferFixtures

  import WeddingPlanner.ReferenceFixtures,
    only: [write_fixture!: 3, tmp_upload_dir!: 0, track_uploads_dir: 0]

  alias WeddingPlanner.Categories
  alias WeddingPlanner.Log.EntityRef
  alias WeddingPlanner.Log.Entry
  alias WeddingPlanner.Offers
  alias WeddingPlanner.Offers.Offer
  alias WeddingPlanner.Realtime
  alias WeddingPlanner.References
  alias WeddingPlanner.References.Storage
  alias WeddingPlannerWeb.Format

  setup do
    scope = scope_fixture()
    category = category_fixture(scope)
    %{scope: scope, category: category}
  end

  defp entries, do: Repo.all(from e in Entry, order_by: e.id)

  defp entries_after(count) when is_integer(count) do
    entries() |> Enum.drop(count)
  end

  # -- create_offer/3 -------------------------------------------------------------------

  describe "create_offer/3 (CST-10)" do
    test "creates an offer with the defaults", %{scope: scope, category: category} do
      assert {:ok, offer} =
               Offers.create_offer(scope, category, %{"vendor_name" => "Kasteel Heers"})

      assert offer.vendor_name == "Kasteel Heers"
      assert offer.category_id == category.id
      assert offer.status == :considering
      assert offer.vat_basis == :inclusive
      assert is_nil(offer.vat_rate_bp)
      assert is_nil(offer.minimum_spend)
      assert is_nil(offer.url)
      assert is_nil(offer.notes)
    end

    test "requires a vendor name", %{scope: scope, category: category} do
      assert {:error, changeset} = Offers.create_offer(scope, category, %{"vendor_name" => ""})
      assert "can't be blank" in errors_on(changeset).vendor_name
    end

    test "trims the vendor name", %{scope: scope, category: category} do
      assert {:ok, offer} =
               Offers.create_offer(scope, category, %{"vendor_name" => "  Kasteel Heers  "})

      assert offer.vendor_name == "Kasteel Heers"
    end

    test "rejects a vendor name over 200 characters", %{scope: scope, category: category} do
      too_long = String.duplicate("a", 201)

      assert {:error, changeset} =
               Offers.create_offer(scope, category, %{"vendor_name" => too_long})

      assert errors_on(changeset).vendor_name != []
    end

    test "logs the create (XC-10)", %{scope: scope, category: category} do
      before_count = length(entries())

      assert {:ok, offer} =
               Offers.create_offer(scope, category, %{"vendor_name" => "Kasteel Heers"})

      assert [entry] = entries_after(before_count)
      assert entry.user_id == scope.user.id
      assert entry.entity_type == "offer"
      assert entry.entity_id == offer.id
      assert entry.description == "Wannes added offer 'Kasteel Heers' to Venue"
    end

    test "broadcasts {:created, offer} (XC-01)", %{scope: scope, category: category} do
      Realtime.subscribe(:offer)

      assert {:ok, offer} =
               Offers.create_offer(scope, category, %{"vendor_name" => "Kasteel Heers"})

      assert_received {Realtime, :offer, {:created, ^offer}}
    end
  end

  describe "create_offer/3 — URL (DR-29)" do
    test "accepts an https URL", %{scope: scope, category: category} do
      assert {:ok, offer} =
               Offers.create_offer(scope, category, %{
                 "vendor_name" => "Kasteel Heers",
                 "url" => "https://kasteelheers.example"
               })

      assert offer.url == "https://kasteelheers.example"
    end

    for url <- [
          "javascript:alert(1)",
          "ftp://example.com/file",
          "example.com",
          "data:text/plain;base64,SGVsbG8=",
          "file:///etc/passwd",
          "https://"
        ] do
      test "refuses #{inspect(url)}", %{scope: scope, category: category} do
        assert {:error, changeset} =
                 Offers.create_offer(scope, category, %{
                   "vendor_name" => "Kasteel Heers",
                   "url" => unquote(url)
                 })

        assert errors_on(changeset).url != []
      end
    end

    test "a blank URL is simply unset — not an error", %{scope: scope, category: category} do
      assert {:ok, offer} =
               Offers.create_offer(scope, category, %{
                 "vendor_name" => "Kasteel Heers",
                 "url" => ""
               })

      assert is_nil(offer.url)
    end
  end

  # -- money input (DR-23, DR-18) --------------------------------------------------------

  describe "minimum_spend_input (CST-10, CST-36, DR-23, DR-18)" do
    test "\"2.500\" stores € 2.500,00, VAT inclusive", %{scope: scope, category: category} do
      assert {:ok, offer} =
               Offers.create_offer(scope, category, %{
                 "vendor_name" => "Kasteel Heers",
                 "minimum_spend_input" => "2.500"
               })

      assert Money.equal?(offer.minimum_spend, WeddingPlanner.Money.new(2500))
      assert Format.money(offer.minimum_spend) == "€ 2.500,00"
    end

    test "\"2500,00\" stores the same amount", %{scope: scope, category: category} do
      assert {:ok, offer} =
               Offers.create_offer(scope, category, %{
                 "vendor_name" => "Kasteel Heers",
                 "minimum_spend_input" => "2500,00"
               })

      assert Money.equal?(offer.minimum_spend, WeddingPlanner.Money.new(2500))
    end

    test "\"2500.50\" is refused with the DR-23 comma message", %{
      scope: scope,
      category: category
    } do
      assert {:error, changeset} =
               Offers.create_offer(scope, category, %{
                 "vendor_name" => "Kasteel Heers",
                 "minimum_spend_input" => "2500.50"
               })

      assert "Use a comma for the decimal part (cents) — for example 45000,50, not 45000.50." in errors_on(
               changeset
             ).minimum_spend_input
    end

    test "an explicit empty string clears minimum_spend back to unset", %{
      scope: scope,
      category: category
    } do
      {:ok, with_min} =
        Offers.create_offer(scope, category, %{
          "vendor_name" => "Kasteel Heers",
          "minimum_spend_input" => "1000"
        })

      assert %Money{} = with_min.minimum_spend

      assert {:ok, cleared} =
               Offers.update_offer(scope, with_min, %{"minimum_spend_input" => ""})

      assert is_nil(cleared.minimum_spend)
    end

    test "omitting the key leaves minimum_spend untouched", %{scope: scope, category: category} do
      {:ok, with_min} =
        Offers.create_offer(scope, category, %{
          "vendor_name" => "Kasteel Heers",
          "minimum_spend_input" => "1000"
        })

      assert {:ok, unchanged} = Offers.update_offer(scope, with_min, %{"notes" => "Great deal"})
      assert Money.equal?(unchanged.minimum_spend, with_min.minimum_spend)
    end
  end

  # -- VAT basis and rate (CST-33, DR-40) ------------------------------------------------

  describe "VAT basis and rate (CST-33, DR-40)" do
    test "inclusive offers have no rate by default", %{scope: scope, category: category} do
      assert {:ok, offer} =
               Offers.create_offer(scope, category, %{"vendor_name" => "Kasteel Heers"})

      assert offer.vat_basis == :inclusive
      assert is_nil(offer.vat_rate_bp)
      assert is_nil(Offer.vat_rate(offer))
    end

    test "exclusive with a rate stores the parsed basis points", %{
      scope: scope,
      category: category
    } do
      assert {:ok, offer} =
               Offers.create_offer(scope, category, %{
                 "vendor_name" => "Kasteel Heers",
                 "vat_basis" => "exclusive",
                 "vat_rate_input" => "21"
               })

      assert offer.vat_basis == :exclusive
      assert offer.vat_rate_bp == 2100
      assert Decimal.equal?(Offer.vat_rate(offer), Decimal.new("0.21"))
    end

    test "exclusive without a rate is refused", %{scope: scope, category: category} do
      assert {:error, changeset} =
               Offers.create_offer(scope, category, %{
                 "vendor_name" => "Kasteel Heers",
                 "vat_basis" => "exclusive"
               })

      assert "can't be blank" in errors_on(changeset).vat_rate_input
    end

    test "exclusive with a blank rate is refused", %{scope: scope, category: category} do
      assert {:error, changeset} =
               Offers.create_offer(scope, category, %{
                 "vendor_name" => "Kasteel Heers",
                 "vat_basis" => "exclusive",
                 "vat_rate_input" => ""
               })

      assert "can't be blank" in errors_on(changeset).vat_rate_input
    end

    test "an invalid rate ('5.5', dot trap) is refused with VatRate's message", %{
      scope: scope,
      category: category
    } do
      assert {:error, changeset} =
               Offers.create_offer(scope, category, %{
                 "vendor_name" => "Kasteel Heers",
                 "vat_basis" => "exclusive",
                 "vat_rate_input" => "5.5"
               })

      assert "Use a comma for the decimal part — for example 5,5, not 5.5." in errors_on(
               changeset
             ).vat_rate_input
    end

    test "switching to inclusive clears the rate and logs it", %{
      scope: scope,
      category: category
    } do
      {:ok, exclusive} =
        Offers.create_offer(scope, category, %{
          "vendor_name" => "Kasteel Heers",
          "vat_basis" => "exclusive",
          "vat_rate_input" => "21"
        })

      before_count = length(entries())

      assert {:ok, inclusive} =
               Offers.update_offer(scope, exclusive, %{"vat_basis" => "inclusive"})

      assert inclusive.vat_basis == :inclusive
      assert is_nil(inclusive.vat_rate_bp)

      new_entries = entries_after(before_count)
      descriptions = Enum.map(new_entries, & &1.description)

      assert "Wannes changed the VAT basis of offer 'Kasteel Heers': exclusive → inclusive" in descriptions

      assert "Wannes changed the VAT rate of offer 'Kasteel Heers': 21 % → none" in descriptions
    end

    test "an already-inclusive offer updated on another field logs no spurious VAT-rate entry",
         %{scope: scope, category: category} do
      {:ok, offer} = Offers.create_offer(scope, category, %{"vendor_name" => "Kasteel Heers"})
      before_count = length(entries())

      {:ok, _} = Offers.update_offer(scope, offer, %{"notes" => "Lovely venue"})

      new_entries = entries_after(before_count)

      assert Enum.map(new_entries, & &1.description) == [
               "Wannes changed the notes of offer 'Kasteel Heers': none → Lovely venue"
             ]
    end
  end

  # -- status / confirmed (CST-40, CST-42, DR-40) ----------------------------------------

  describe "status: confirmed is refused both ways (CST-40, DR-40)" do
    test "moving to confirmed is refused", %{scope: scope, category: category} do
      {:ok, offer} = Offers.create_offer(scope, category, %{"vendor_name" => "Kasteel Heers"})

      assert {:error, changeset} = Offers.update_offer(scope, offer, %{"status" => "confirmed"})
      assert errors_on(changeset).status != []
      assert Offers.get_offer!(offer.id).status == :considering
    end

    test "moving from confirmed is refused (test seam — status forced via raw update)", %{
      scope: scope,
      category: category
    } do
      {:ok, offer} = Offers.create_offer(scope, category, %{"vendor_name" => "Kasteel Heers"})
      confirmed = offer |> Ecto.Changeset.change(status: :confirmed) |> Repo.update!()

      assert {:error, changeset} =
               Offers.update_offer(scope, confirmed, %{"status" => "shortlisted"})

      assert errors_on(changeset).status != []
    end

    test "considering/shortlisted/rejected transitions among themselves are fine", %{
      scope: scope,
      category: category
    } do
      {:ok, offer} = Offers.create_offer(scope, category, %{"vendor_name" => "Kasteel Heers"})

      assert {:ok, shortlisted} =
               Offers.update_offer(scope, offer, %{"status" => "shortlisted"})

      assert shortlisted.status == :shortlisted

      assert {:ok, rejected} = Offers.update_offer(scope, shortlisted, %{"status" => "rejected"})
      assert rejected.status == :rejected
    end

    test "editing another field of an already-confirmed offer still works", %{
      scope: scope,
      category: category
    } do
      {:ok, offer} = Offers.create_offer(scope, category, %{"vendor_name" => "Kasteel Heers"})
      confirmed = offer |> Ecto.Changeset.change(status: :confirmed) |> Repo.update!()

      assert {:ok, updated} = Offers.update_offer(scope, confirmed, %{"notes" => "Booked"})
      assert updated.status == :confirmed
      assert updated.notes == "Booked"
    end
  end

  # -- update_offer/3 per-field logging (XC-10) ------------------------------------------

  describe "update_offer/3 per-field logging (XC-10)" do
    setup %{scope: scope, category: category} do
      {:ok, offer} = Offers.create_offer(scope, category, %{"vendor_name" => "Kasteel Heers"})
      %{offer: offer}
    end

    test "logs the status change with the exact wording", %{scope: scope, offer: offer} do
      before_count = length(entries())
      {:ok, _} = Offers.update_offer(scope, offer, %{"status" => "shortlisted"})

      assert Enum.map(entries_after(before_count), & &1.description) == [
               "Wannes changed the status of offer 'Kasteel Heers': considering → shortlisted"
             ]
    end

    test "logs a vendor name change", %{scope: scope, offer: offer} do
      before_count = length(entries())
      {:ok, _} = Offers.update_offer(scope, offer, %{"vendor_name" => "Kasteel Heers BV"})

      assert Enum.map(entries_after(before_count), & &1.description) == [
               "Wannes changed the vendor of offer 'Kasteel Heers': Kasteel Heers → Kasteel Heers BV"
             ]
    end

    test "logs a URL change, unset displayed as 'none'", %{scope: scope, offer: offer} do
      before_count = length(entries())
      {:ok, _} = Offers.update_offer(scope, offer, %{"url" => "https://kasteelheers.example"})

      assert Enum.map(entries_after(before_count), & &1.description) == [
               "Wannes changed the URL of offer 'Kasteel Heers': none → https://kasteelheers.example"
             ]
    end

    test "logs a minimum spend change through Format.money/1", %{scope: scope, offer: offer} do
      before_count = length(entries())

      {:ok, _} =
        Offers.update_offer(scope, offer, %{"minimum_spend_input" => "2.500"})

      assert Enum.map(entries_after(before_count), & &1.description) == [
               "Wannes changed the minimum spend of offer 'Kasteel Heers': none → € 2.500,00"
             ]
    end

    test "no change, no entry", %{scope: scope, offer: offer} do
      before_count = length(entries())
      {:ok, _} = Offers.update_offer(scope, offer, %{"vendor_name" => offer.vendor_name})

      assert entries_after(before_count) == []
    end

    test "broadcasts {:updated, offer} (XC-01)", %{scope: scope, offer: offer} do
      Realtime.subscribe(:offer)

      assert {:ok, updated} = Offers.update_offer(scope, offer, %{"status" => "shortlisted"})
      assert_received {Realtime, :offer, {:updated, ^updated}}
    end
  end

  # -- category existence (DR-40 boundary rule) ------------------------------------------

  describe "change_offer/2 — category existence (SQLite foreign_key_constraint/2 limitation)" do
    test "a category deleted between form render and submit is refused, not raised", %{
      scope: scope,
      category: category
    } do
      # No services/offers on this category yet, so the delete itself succeeds — this
      # pins the race the moduledoc describes: the caller still holds the now-stale
      # `category.id` and tries to build an offer against it.
      {:ok, _} = Categories.delete_category(scope, category)

      changeset = Offers.change_offer(%Offer{category_id: category.id}, %{"vendor_name" => "X"})

      refute changeset.valid?
      assert "does not exist" in errors_on(changeset).category_id
    end

    test "an existing category is not flagged", %{category: category} do
      changeset = Offers.change_offer(%Offer{category_id: category.id}, %{"vendor_name" => "X"})
      assert errors_on(changeset)[:category_id] in [nil, []]
    end
  end

  # -- delete_offer/2 (XC-24) -------------------------------------------------------------

  describe "delete_offer/2 (XC-24, XC-10, XC-01)" do
    setup %{scope: scope, category: category} do
      {:ok, offer} = Offers.create_offer(scope, category, %{"vendor_name" => "Kasteel Heers"})
      %{offer: offer, before: track_uploads_dir(), src: tmp_upload_dir!()}
    end

    test "deletes an offer with no references", %{scope: scope, offer: offer} do
      assert {:ok, deleted} = Offers.delete_offer(scope, offer)
      assert deleted.id == offer.id
      assert_raise Ecto.NoResultsError, fn -> Offers.get_offer!(offer.id) end
    end

    test "offer_deletion_effects/1 is empty when it has no references", %{offer: offer} do
      assert Offers.offer_deletion_effects(offer) == []
    end

    test "offer_deletion_effects/1 counts attached references", %{
      scope: scope,
      offer: offer,
      src: src
    } do
      owner = Offers.reference_owner(offer)

      {:ok, _} =
        References.create_url_reference(scope, owner, %{
          "label" => "Site",
          "url" => "https://a.example"
        })

      {:ok, _} =
        References.create_file_reference(
          scope,
          owner,
          %{"label" => "Quote"},
          write_fixture!(src, :pdf, "a.pdf")
        )

      assert Offers.offer_deletion_effects(offer) == [
               %{label: "2 references are deleted (1 file, 1 link)", count: 2}
             ]
    end

    test "deletes the offer's references (row and file, purged after commit), one summary and one child per reference",
         %{scope: scope, offer: offer, src: src} do
      owner = Offers.reference_owner(offer)

      {:ok, file_ref} =
        References.create_file_reference(
          scope,
          owner,
          %{"label" => "Quote"},
          write_fixture!(src, :pdf, "a.pdf")
        )

      {:ok, link_ref} =
        References.create_url_reference(scope, owner, %{
          "label" => "Site",
          "url" => "https://a.example"
        })

      before_count = length(entries())
      Realtime.subscribe(:reference)
      Realtime.subscribe(:offer)

      assert {:ok, _deleted} = Offers.delete_offer(scope, offer)

      # References gone, files purged.
      assert Repo.aggregate(WeddingPlanner.References.Reference, :count) == 0
      refute Storage.exists?(file_ref)

      new_entries = entries_after(before_count)
      {[summary], children} = Enum.split_with(new_entries, &is_nil(&1.entity_type))

      assert summary.description == "Wannes deleted offer 'Kasteel Heers'"
      assert Enum.all?(children, &(&1.parent_id == summary.id))
      assert Enum.all?(children, &(&1.entity_type == "offer"))
      assert Enum.all?(children, &(&1.entity_id == offer.id))

      assert Enum.sort(Enum.map(children, & &1.description)) ==
               Enum.sort([
                 "Wannes removed reference 'Quote' (offer 'Kasteel Heers' deleted)",
                 "Wannes removed reference 'Site' (offer 'Kasteel Heers' deleted)"
               ])

      for id <- [file_ref.id, link_ref.id] do
        assert_received {Realtime, :reference, {:deleted, ^id}}
      end

      offer_id = offer.id
      assert_received {Realtime, :offer, {:deleted, ^offer_id}}
    end

    test "a raw delete of the offer before its references raises (restrict FK) — fail-proof (c)",
         %{scope: scope, offer: offer, src: src} do
      owner = Offers.reference_owner(offer)

      {:ok, _} =
        References.create_file_reference(
          scope,
          owner,
          %{"label" => "Quote"},
          write_fixture!(src, :pdf, "a.pdf")
        )

      assert_raise Ecto.ConstraintError, fn -> Repo.delete(offer) end
    end
  end

  # -- DR-26 Q11: category_deletion_blockers/1 counts offers -----------------------------

  describe "Categories.category_deletion_blockers/1 counts offers (DR-26 Q11)" do
    test "is empty for a category with no offers", %{category: category} do
      assert Categories.category_deletion_blockers(category) == []
    end

    test "counts offers, singular for one", %{scope: scope, category: category} do
      {:ok, _} = Offers.create_offer(scope, category, %{"vendor_name" => "Kasteel Heers"})

      assert Categories.category_deletion_blockers(category) == [
               %{label: "1 offer", count: 1}
             ]
    end

    test "counts offers, plural for several", %{scope: scope, category: category} do
      {:ok, _} = Offers.create_offer(scope, category, %{"vendor_name" => "Kasteel Heers"})
      {:ok, _} = Offers.create_offer(scope, category, %{"vendor_name" => "Domein X"})

      assert Categories.category_deletion_blockers(category) == [
               %{label: "2 offers", count: 2}
             ]
    end

    test "Categories.delete_category/2 refuses when the category has offers", %{
      scope: scope,
      category: category
    } do
      {:ok, _} = Offers.create_offer(scope, category, %{"vendor_name" => "Kasteel Heers"})

      assert Categories.delete_category(scope, category) == {:error, :has_blockers}
      assert Categories.get_category!(category.id)
    end
  end

  # -- WeddingPlanner.Log.EntityRef "offer" resolver (XC-10) -----------------------------

  describe "EntityRef 'offer' resolver (XC-10)" do
    test "an existing offer resolves to '<vendor> (<category>)' and /offers/:id", %{
      scope: scope,
      category: category
    } do
      {:ok, offer} = Offers.create_offer(scope, category, %{"vendor_name" => "Kasteel Heers"})

      assert {:link, "Kasteel Heers (Venue)", "/offers/" <> id} =
               EntityRef.resolve("offer", offer.id)

      assert id == to_string(offer.id)
    end

    test "a deleted offer degrades to text", %{scope: scope, category: category} do
      {:ok, offer} = Offers.create_offer(scope, category, %{"vendor_name" => "Kasteel Heers"})
      {:ok, _} = Offers.delete_offer(scope, offer)

      assert {:text, _label} = EntityRef.resolve("offer", offer.id)
    end
  end

  # -- get_offer!/1, list_offers/1, count_offers/1 ----------------------------------------

  describe "get_offer!/1, list_offers/1, count_offers/1" do
    test "get_offer!/1 preloads the category", %{scope: scope, category: category} do
      {:ok, offer} = Offers.create_offer(scope, category, %{"vendor_name" => "Kasteel Heers"})

      fetched = Offers.get_offer!(offer.id)
      assert fetched.category.id == category.id
    end

    test "list_offers/1 returns a category's offers in id order", %{
      scope: scope,
      category: category
    } do
      {:ok, a} = Offers.create_offer(scope, category, %{"vendor_name" => "A"})
      {:ok, b} = Offers.create_offer(scope, category, %{"vendor_name" => "B"})

      assert Enum.map(Offers.list_offers(category), & &1.id) == [a.id, b.id]
      assert Enum.map(Offers.list_offers(category.id), & &1.id) == [a.id, b.id]
    end

    test "list_offers/1 never returns another category's offers", %{
      scope: scope,
      category: category
    } do
      {:ok, other} = Categories.create_category(scope, %{"name" => "Catering"})
      {:ok, _} = Offers.create_offer(scope, other, %{"vendor_name" => "Traiteur"})

      assert Offers.list_offers(category) == []
    end

    test "count_offers/1", %{scope: scope, category: category} do
      assert Offers.count_offers(category) == 0
      {:ok, _} = Offers.create_offer(scope, category, %{"vendor_name" => "Kasteel Heers"})
      assert Offers.count_offers(category) == 1
    end
  end

  # -- Snapshot integration ---------------------------------------------------------------

  describe "WeddingPlanner.Valuation.Snapshot integration (C2)" do
    test "offers load, in id order", %{scope: scope, category: category} do
      {:ok, a} = Offers.create_offer(scope, category, %{"vendor_name" => "A"})
      {:ok, b} = Offers.create_offer(scope, category, %{"vendor_name" => "B"})

      snapshot = WeddingPlanner.Valuation.Snapshot.load(Repo)
      assert Enum.map(snapshot.offers, & &1.id) == [a.id, b.id]
    end
  end
end
