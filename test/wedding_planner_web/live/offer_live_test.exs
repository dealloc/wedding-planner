defmodule WeddingPlannerWeb.Live.OfferLiveTest do
  @moduledoc """
  `docs/modules/offers-and-comparison.md` `CST-10`, `CST-33`, `CST-36`; `docs/04-cross-cutting.md`
  `XC-01`, `XC-10`, `XC-11`, `XC-20`–`XC-24`, `XC-40`; `DR-18`, `DR-23`, `DR-28`, `DR-31`,
  `DR-40` — the offer's own page (task 51).

  `async: false`: the reference upload tests write real files under `:uploads_dir`, the
  same reason `WeddingPlannerWeb.ReferencesComponentTest` and `WeddingPlanner.OffersTest`
  are `async: false`.
  """
  use WeddingPlannerWeb.ConnCase, async: false

  import Phoenix.LiveViewTest
  import WeddingPlanner.OfferFixtures

  import WeddingPlanner.ReferenceFixtures,
    only: [bytes: 1, track_uploads_dir: 0]

  alias WeddingPlanner.Accounts.Scope
  alias WeddingPlanner.Accounts.User
  alias WeddingPlanner.Offers
  alias WeddingPlanner.References
  alias WeddingPlanner.References.Storage
  alias WeddingPlanner.Repo

  setup %{conn: conn} do
    user = insert_user!("Wannes")
    scope = Scope.for_user(user)
    category = category_fixture(scope)

    %{
      conn: log_in_user(conn, user),
      user: user,
      scope: scope,
      category: category,
      before_uploads: track_uploads_dir()
    }
  end

  defp find(html, selector), do: html |> LazyHTML.from_fragment() |> LazyHTML.query(selector)
  defp attr(html, selector, name), do: html |> find(selector) |> LazyHTML.attribute(name)

  describe "authentication" do
    test "an unauthenticated request redirects to /login", %{scope: scope, category: category} do
      offer = offer_fixture(scope, category)

      conn = Phoenix.ConnTest.build_conn()
      conn = get(conn, ~p"/offers/#{offer.id}")

      assert redirected_to(conn) == "/login?return_to=%2Foffers%2F#{offer.id}"
    end
  end

  describe "show" do
    test "shows the vendor name, status pill and a back link to the category", %{
      conn: conn,
      scope: scope,
      category: category
    } do
      offer = offer_fixture(scope, category)

      {:ok, view, html} = live(conn, ~p"/offers/#{offer.id}")

      assert html =~ "Kasteel Heers"
      assert has_element?(view, "#offer-status-pill", "Considering")
      assert has_element?(view, "#offer-back-to-category", category.name)
    end

    test "a non-existent offer 404s" do
      user = insert_user!("Solo")
      conn = build_conn() |> log_in_user(user)

      assert_raise Ecto.NoResultsError, fn ->
        live(conn, ~p"/offers/999999")
      end
    end
  end

  describe "header form validation (CST-10, CST-33, CST-36, DR-23)" do
    setup %{scope: scope, category: category} do
      %{offer: offer_fixture(scope, category)}
    end

    test "a bad money amount shows the DR-23 message", %{conn: conn, offer: offer} do
      {:ok, view, _html} = live(conn, ~p"/offers/#{offer.id}")

      html =
        view
        |> form("#offer-form", offer: %{"minimum_spend_input" => "2500.50"})
        |> render_change()

      assert html =~ "Use a comma for the decimal part"
    end

    test "exclusive without a rate shows an error on submit", %{conn: conn, offer: offer} do
      {:ok, view, _html} = live(conn, ~p"/offers/#{offer.id}")

      # Switch to exclusive first (this is what makes `#offer-form-vat-rate` exist in
      # the DOM at all — it prefills "21"), then explicitly blank the rate back out
      # before submitting, exactly like a user clearing the field would.
      view
      |> form("#offer-form", offer: %{"vat_basis" => "exclusive"})
      |> render_change()

      html =
        view
        |> form("#offer-form", offer: %{"vat_basis" => "exclusive", "vat_rate_input" => ""})
        |> render_submit()

      assert html =~ "can&#39;t be blank"
      assert Offers.get_offer!(offer.id).vat_basis == :inclusive
    end

    test "confirmed is never offered as a status option", %{conn: conn, offer: offer} do
      {:ok, view, _html} = live(conn, ~p"/offers/#{offer.id}")

      html = render(view)
      assert attr(html, "#offer-form-status option[value=confirmed]", "value") == []
    end
  end

  describe "header form save (CST-10, CST-33, CST-36)" do
    setup %{scope: scope, category: category} do
      %{offer: offer_fixture(scope, category)}
    end

    test "saving persists and a re-mount shows the new values", %{conn: conn, offer: offer} do
      {:ok, view, _html} = live(conn, ~p"/offers/#{offer.id}")

      # Switch to exclusive first so `#offer-form-vat-rate` exists in the DOM — a bare
      # `<select phx-change>` outside a `<form>` is silently dropped by real browsers,
      # but the whole point here is that this select lives inside `#offer-form`.
      view
      |> form("#offer-form", offer: %{"vat_basis" => "exclusive"})
      |> render_change()

      view
      |> form("#offer-form",
        offer: %{
          "vendor_name" => "Kasteel Heers BV",
          "status" => "shortlisted",
          "vat_basis" => "exclusive",
          "vat_rate_input" => "21",
          "minimum_spend_input" => "7.000",
          "url" => "https://kasteelheers.example.com",
          "notes" => "Great venue"
        }
      )
      |> render_submit()

      assert has_element?(view, "#offer-status-pill", "Shortlisted")

      {:ok, view2, html} = live(conn, ~p"/offers/#{offer.id}")

      assert html =~ "Kasteel Heers BV"
      assert has_element?(view2, "#offer-form-vendor[value=\"Kasteel Heers BV\"]")
      assert has_element?(view2, "#offer-form-vat-rate[value=\"21\"]")

      assert has_element?(view2, "#offer-form-minimum-spend[value=\"7.000,00\"]") or
               has_element?(view2, "#offer-form-minimum-spend[value=\"7.000\"]")

      assert attr(html, "#offer-url-link", "target") == ["_blank"]
      assert attr(html, "#offer-url-link", "rel") == ["noopener noreferrer"]

      reloaded = Offers.get_offer!(offer.id)
      assert reloaded.vendor_name == "Kasteel Heers BV"
      assert reloaded.status == :shortlisted
      assert reloaded.vat_basis == :exclusive
      assert reloaded.vat_rate_bp == 2100
    end

    test "history shows one entry per changed field", %{conn: conn, offer: offer} do
      {:ok, view, _html} = live(conn, ~p"/offers/#{offer.id}")

      view
      |> form("#offer-form",
        offer: %{"vendor_name" => "Kasteel Heers", "status" => "shortlisted"}
      )
      |> render_submit()

      assert has_element?(view, "#offer-history", "changed the status")
    end

    test "switching to inclusive hides and clears the rate", %{
      conn: conn,
      scope: scope,
      offer: offer
    } do
      {:ok, updated} =
        Offers.update_offer(scope, offer, %{"vat_basis" => "exclusive", "vat_rate_input" => "21"})

      assert updated.vat_rate_bp == 2100

      {:ok, view, _html} = live(conn, ~p"/offers/#{updated.id}")
      assert has_element?(view, "#offer-form-vat-rate")

      view
      |> form("#offer-form", offer: %{"vat_basis" => "inclusive"})
      |> render_change()

      refute has_element?(view, "#offer-form-vat-rate")

      view
      |> form("#offer-form", offer: %{"vat_basis" => "inclusive"})
      |> render_submit()

      assert is_nil(Offers.get_offer!(updated.id).vat_rate_bp)
    end

    test "switching to exclusive prefills 21 as the rate", %{conn: conn, offer: offer} do
      {:ok, view, _html} = live(conn, ~p"/offers/#{offer.id}")

      view
      |> form("#offer-form", offer: %{"vat_basis" => "exclusive"})
      |> render_change()

      assert has_element?(view, "#offer-form-vat-rate[value=\"21\"]")
    end
  end

  describe "references (DR-28, DR-31 — B1's deferred real-browser check is closed by the CDP run)" do
    setup %{scope: scope, category: category} do
      %{offer: offer_fixture(scope, category)}
    end

    test "a URL reference appears in the list and the offer's history", %{
      conn: conn,
      offer: offer
    } do
      {:ok, view, _html} = live(conn, ~p"/offers/#{offer.id}")

      view
      |> form("#offer-references-url-form",
        url: %{"label" => "Website", "url" => "https://example.com"}
      )
      |> render_submit()

      assert has_element?(view, "#offer-references-list", "Website")

      [reference] = References.list_references(Offers.reference_owner(offer))
      assert reference.kind == :url
      assert has_element?(view, "#offer-history", "added link 'Website'")
    end

    test "a file upload through the component appears in the list and the offer's history",
         %{conn: conn, offer: offer} do
      {:ok, view, _html} = live(conn, ~p"/offers/#{offer.id}")

      content = bytes(:png)

      avatar =
        file_input(view, "#offer-references-upload-form", :file, [
          %{name: "photo.png", content: content, size: byte_size(content), type: "image/png"}
        ])

      assert render_upload(avatar, "photo.png") =~ "100"

      view
      |> element("#offer-references-upload-form")
      |> render_submit(%{"file" => %{"label" => "Photo"}})

      assert has_element?(view, "#offer-references-list", "Photo")
      assert has_element?(view, "#offer-history", "attached 'Photo'")
    end

    test "a second viewer of the same offer sees a reference added by the first, via the host's own refetch",
         %{conn: conn, offer: offer} do
      # `ReferencesComponent` never fetches its own references (`DR-28`'s host
      # contract) — a mutation made by the acting browser is shown to *that* browser
      # only because the component's own event handler (`save_url`/`save_upload`)
      # inserts it directly into its own stream. A *second* viewer of the same offer
      # only ever finds out because their own `OfferLive` process receives the
      # `:reference` broadcast and calls `handle_info({Realtime, :reference, _event},
      # socket)`, which refetches `References.list_references/1` and re-assigns
      # `:references` — which is what makes the *second* view's `<.live_component>`
      # call pass different assigns on its next render, triggering the component's own
      # `update/2` to reset its stream from the fresh list. This is the scenario the
      # fail-proof in the task report actually exercises (see the report for the
      # before/after `mix test` output with `handle_info({Realtime, :reference, _},
      # socket)` stubbed to `{:noreply, socket}`).
      {:ok, view1, _html} = live(conn, ~p"/offers/#{offer.id}")
      {:ok, view2, _html} = live(conn, ~p"/offers/#{offer.id}")

      view1
      |> form("#offer-references-url-form",
        url: %{"label" => "Website", "url" => "https://example.com"}
      )
      |> render_submit()

      # Synchronise on view2's own mailbox before asserting — it must have already
      # processed the `:reference` broadcast, not just have it queued.
      _ = :sys.get_state(view2.pid)

      assert has_element?(view2, "#offer-references-list", "Website")
    end
  end

  describe "delete (XC-24, XC-40)" do
    setup %{scope: scope, category: category} do
      %{offer: offer_fixture(scope, category)}
    end

    test "shows the references effect and removes the offer, purging files", %{
      conn: conn,
      scope: scope,
      offer: offer
    } do
      {:ok, reference} =
        References.create_url_reference(scope, Offers.reference_owner(offer), %{
          "label" => "Site",
          "url" => "https://example.com"
        })

      dir = WeddingPlanner.ReferenceFixtures.tmp_upload_dir!()
      {path, name} = WeddingPlanner.ReferenceFixtures.write_fixture!(dir, :png, "photo.png")

      {:ok, file_reference} =
        References.create_file_reference(
          scope,
          Offers.reference_owner(offer),
          %{"label" => "Photo"},
          {path, name}
        )

      stored_path = Storage.path_for(file_reference)
      assert File.exists?(stored_path)

      {:ok, view, _html} = live(conn, ~p"/offers/#{offer.id}")

      view |> element("#offer-delete") |> render_click()
      assert has_element?(view, "#offer-delete-confirm", "reference")

      view |> element("#offer-delete-confirm-confirm") |> render_click()

      assert_raise Ecto.NoResultsError, fn -> Offers.get_offer!(offer.id) end
      refute File.exists?(stored_path)

      assert reference.id
    end

    test "another process deleting the offer navigates the viewer to the category", %{
      conn: conn,
      scope: scope,
      offer: offer,
      category: category
    } do
      {:ok, view, _html} = live(conn, ~p"/offers/#{offer.id}")

      {:ok, _} = Offers.delete_offer(scope, offer)

      assert_redirect(view, ~p"/categories/#{category.id}")
    end
  end

  defp insert_user!(display_name) do
    %User{} |> User.changeset(%{display_name: display_name}) |> Repo.insert!()
  end
end
