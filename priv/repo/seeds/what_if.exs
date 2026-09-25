defmodule WeddingPlanner.Seeds.WhatIf do
  @moduledoc """
  The B4 demo household (task 89; `DR-79`, `DR-82`): group "Family Janssens" (type label
  "household") — Tom Janssens and Els Janssens (adults) and Lotte Janssens (child), want
  tier *maybe*, certainty *likely*, **no invitations** — ready to be invited to Dinner
  from `/what-if` (the B-list `INVT-04` demo screenshot needs someone genuinely not
  counted yet).

  Idempotent by group name (independent of `people.exs`'s own "no persons yet" guard,
  since this block is appended after every other wave's demo data already exists):
  skips with one line, never raises, when a group named "Family Janssens" already
  exists.
  """

  alias WeddingPlanner.Accounts.Scope
  alias WeddingPlanner.Guests

  @group_name "Family Janssens"

  @spec run(Scope.t()) :: :ok
  def run(%Scope{} = scope) do
    if Enum.any?(Guests.list_groups(), &(&1.name == @group_name)) do
      IO.puts("what_if: #{@group_name} already present — skipped")
    else
      {:ok, group} = Guests.create_group(scope, %{name: @group_name, type_label: "household"})

      members = [
        %{first_name: "Tom", last_name: "Janssens", age_category: :adult},
        %{first_name: "Els", last_name: "Janssens", age_category: :adult},
        %{first_name: "Lotte", last_name: "Janssens", age_category: :child}
      ]

      {:ok, created} =
        Guests.bulk_create_persons(scope, members, %{
          group_id: group.id,
          want_tier: :maybe,
          certainty: :likely
        })

      IO.puts("what_if: created group '#{@group_name}' with #{length(created)} people")
    end

    :ok
  end
end
