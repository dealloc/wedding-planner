defmodule WeddingPlanner.Seeds.Categories do
  @moduledoc """
  `DR-26` Q4 demo cost categories: mirrors `docs/modules/offers-and-comparison.md`'s
  worked examples — Venue's five services (the CST-32 minimum-charge example), Catering
  with a VAT-exclusive worked example, and Attire's target per normative example B3
  (`docs/07-normative-examples.md`) — plus Church, Photography and Flowers with no
  services yet, so later comparison-matrix slices (C2+) can demo against real rows.
  Money targets are parsed from nl-BE input strings through
  `WeddingPlanner.Categories.create_category/2` (`DR-23`) — never constructed directly
  (`DR-18`). Idempotent: runs only while the `categories` table is empty — see
  `priv/repo/seeds.exs`.
  """

  alias WeddingPlanner.Accounts.Scope
  alias WeddingPlanner.Categories
  alias WeddingPlanner.Categories.Category
  alias WeddingPlanner.Repo

  @spec run(Scope.t()) :: :ok
  def run(%Scope{} = scope) do
    if Repo.aggregate(Category, :count) == 0 do
      categories_list = categories()
      Enum.each(categories_list, &seed_category(scope, &1))
      IO.puts("categories: created #{length(categories_list)} categories")
    else
      IO.puts("skipping categories — already has data")
    end

    :ok
  end

  defp seed_category(scope, {name, target_input, services}) do
    attrs = category_attrs(name, target_input)
    {:ok, category} = Categories.create_category(scope, attrs)

    Enum.each(services, fn {service_name, priority} ->
      {:ok, _service} =
        Categories.create_service(scope, category, %{
          name: service_name,
          wanted_priority: priority
        })
    end)
  end

  defp category_attrs(name, nil), do: %{name: name}
  defp category_attrs(name, target_input), do: %{name: name, target_input: target_input}

  defp categories do
    [
      {"Venue", "12.000",
       [
         {"Seating", :nice_to_have},
         {"Catering", :must_have},
         {"Sound", :nice_to_have},
         {"Garden ceremony", :not_wanted},
         {"Late-night snack", :nice_to_have}
       ]},
      {"Catering", "7.000",
       [
         {"Dinner catering", :must_have},
         {"Drinks", :nice_to_have}
       ]},
      {"Church", nil, []},
      {"Attire", "2.500", []},
      {"Photography", nil, []},
      {"Flowers", nil, []}
    ]
  end
end
