defmodule WeddingPlanner.Offers.OverrideTest do
  @moduledoc """
  `WeddingPlanner.Offers.toggle_override/3` and `list_overrides/1`
  (`docs/modules/offers-and-comparison.md` `CST-24`, `CST-52`; `DR-49`, `DR-56`).
  """
  use WeddingPlanner.DataCase, async: true

  import WeddingPlanner.OfferFixtures

  alias WeddingPlanner.Categories
  alias WeddingPlanner.Log.Entry
  alias WeddingPlanner.Offers
  alias WeddingPlanner.Offers.Override
  alias WeddingPlanner.Realtime

  setup do
    scope = scope_fixture()
    category = category_fixture(scope)
    offer = offer_fixture(scope, category)
    %{scope: scope, category: category, offer: offer}
  end

  defp entries, do: Repo.all(from e in Entry, order_by: e.id)
  defp entries_after(count) when is_integer(count), do: entries() |> Enum.drop(count)

  # -- toggle_override/3 -----------------------------------------------------------------

  describe "toggle_override/3 (CST-24, CST-52)" do
    test "a nice-to-have service: first toggle turns it off, writes a row, logs and broadcasts",
         %{scope: scope, category: category, offer: offer} do
      service = service_fixture(scope, category, %{"name" => "Sound"})
      before_count = length(entries())
      Realtime.subscribe(:override)

      assert {:ok, %{wanted: false, override: %Override{} = override}} =
               Offers.toggle_override(scope, offer, service)

      assert override.offer_id == offer.id
      assert override.service_id == service.id
      assert override.wanted == false

      assert [entry] = entries_after(before_count)

      assert entry.description ==
               "Wannes turned off 'Sound' for offer 'Kasteel Heers' (override)"

      assert entry.entity_type == "offer"
      assert entry.entity_id == offer.id

      assert_received {Realtime, :override, {:created, ^override}}
    end

    test "toggling again deletes the row, logs the removal, broadcasts :deleted — fail-proof (1)",
         %{scope: scope, category: category, offer: offer} do
      service = service_fixture(scope, category, %{"name" => "Sound"})
      {:ok, %{override: override}} = Offers.toggle_override(scope, offer, service)

      before_count = length(entries())
      Realtime.subscribe(:override)

      assert {:ok, %{wanted: true, override: nil}} = Offers.toggle_override(scope, offer, service)
      assert Repo.get(Override, override.id) == nil

      assert [entry] = entries_after(before_count)

      assert entry.description ==
               "Wannes removed the override on 'Sound' for offer 'Kasteel Heers'"

      id = override.id
      assert_received {Realtime, :override, {:deleted, ^id}}
    end

    test "a not-wanted service: first toggle turns it on, logs 'turned on'", %{
      scope: scope,
      category: category,
      offer: offer
    } do
      service =
        service_fixture(scope, category, %{
          "name" => "Garden ceremony",
          "wanted_priority" => "not_wanted"
        })

      before_count = length(entries())

      assert {:ok, %{wanted: true, override: override}} =
               Offers.toggle_override(scope, offer, service)

      assert override.wanted == true

      assert [entry] = entries_after(before_count)

      assert entry.description ==
               "Wannes turned on 'Garden ceremony' for offer 'Kasteel Heers' (override)"

      assert {:ok, %{wanted: false, override: nil}} =
               Offers.toggle_override(scope, offer, service)
    end

    test "refuses a service of another category, writes nothing", %{
      scope: scope,
      offer: offer
    } do
      other_category = category_fixture(scope, %{"name" => "Catering"})
      other_service = service_fixture(scope, other_category, %{"name" => "Buffet"})

      assert {:error, :wrong_category} = Offers.toggle_override(scope, offer, other_service)
      assert Offers.list_overrides(offer) == []
    end

    test "a row is kept when the priority later changes — CST-24, DR-56", %{
      scope: scope,
      category: category,
      offer: offer
    } do
      service = service_fixture(scope, category, %{"name" => "Sound"})

      {:ok, %{wanted: false, override: override}} = Offers.toggle_override(scope, offer, service)
      assert override.wanted == false

      {:ok, changed} =
        Categories.update_service(scope, service, %{"wanted_priority" => "not_wanted"})

      # The row is kept, untouched by the priority change alone — now equal to the
      # (new) default but still present.
      stored = Repo.get_by(Override, offer_id: offer.id, service_id: service.id)
      assert stored.id == override.id
      assert stored.wanted == false

      # Toggling now: effective (row) false -> target true; new default (not wanted)
      # false; target != default -> the row is updated, not deleted.
      assert {:ok, %{wanted: true, override: updated}} =
               Offers.toggle_override(scope, offer, changed)

      assert updated.id == override.id
      assert updated.wanted == true
    end

    test "invariant: after every toggle, the stored row (if any) differs from the current default",
         %{scope: scope, category: category, offer: offer} do
      for priority <- ["nice_to_have", "must_have", "not_wanted"] do
        service =
          service_fixture(scope, category, %{
            "name" => "Service #{priority}",
            "wanted_priority" => priority
          })

        default = priority in ["nice_to_have", "must_have"]

        {:ok, _} = Offers.toggle_override(scope, offer, service)
        stored = Repo.get_by(Override, offer_id: offer.id, service_id: service.id)
        assert stored.wanted != default

        assert {:ok, %{override: nil}} = Offers.toggle_override(scope, offer, service)
        assert Repo.get_by(Override, offer_id: offer.id, service_id: service.id) == nil
      end
    end
  end

  # -- list_overrides/1 -------------------------------------------------------------------

  describe "list_overrides/1" do
    test "an offer's override rows, id order", %{scope: scope, category: category, offer: offer} do
      a = service_fixture(scope, category, %{"name" => "A"})
      b = service_fixture(scope, category, %{"name" => "B"})

      {:ok, %{override: override_b}} = Offers.toggle_override(scope, offer, b)
      {:ok, %{override: override_a}} = Offers.toggle_override(scope, offer, a)

      assert Enum.map(Offers.list_overrides(offer), & &1.id) == [override_b.id, override_a.id]
    end

    test "empty for an offer with no overrides", %{offer: offer} do
      assert Offers.list_overrides(offer) == []
    end
  end

  # -- database backstop (raw insert bypassing the changeset) -----------------------------

  describe "unique index backstop" do
    test "a raw duplicate offer_id/service_id pair is refused", %{
      scope: scope,
      category: category,
      offer: offer
    } do
      service = service_fixture(scope, category, %{"name" => "Sound"})
      Repo.insert!(%Override{offer_id: offer.id, service_id: service.id, wanted: false})

      assert_raise Ecto.ConstraintError, ~r/offer_overrides_offer_id_service_id_index/, fn ->
        Repo.insert!(%Override{offer_id: offer.id, service_id: service.id, wanted: true})
      end
    end
  end
end
