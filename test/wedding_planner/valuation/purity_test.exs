defmodule WeddingPlanner.Valuation.PurityTest do
  @moduledoc """
  `NFR-41`, `NFR-13`: every module under `WeddingPlanner.Valuation` is pure — no database
  access except in `WeddingPlanner.Valuation.Snapshot.Loader`, and no Phoenix or web
  layer anywhere.

  Checked on the **compiled** modules rather than the source: every module and literal
  a module's code references is collected from its disassembled BEAM, so an alias, an
  import or a macro expansion (`Ecto.Query.from/2` expands to `Ecto.Query.*` structs)
  cannot hide a reference the way it could from a text search. Module docs and specs are
  not code and are not scanned.

  The one thing a scan of names cannot see is a dynamic call on a repo module passed in
  as an argument (`repo.all(Event)` with no query API in sight). Only
  `WeddingPlanner.Valuation.Snapshot.load/1` is ever handed a repo, and it hands it
  straight to the loader.
  """
  use ExUnit.Case, async: true

  @namespace "Elixir.WeddingPlanner.Valuation"
  @loader WeddingPlanner.Valuation.Snapshot.Loader

  @database ~w(
    Elixir.WeddingPlanner.Repo
    Elixir.Ecto.Query
    Elixir.Ecto.Repo
    Elixir.Ecto.Multi
    Elixir.Ecto.Adapters
    Elixir.DBConnection
    Elixir.Exqlite
  )

  @web ~w(Elixir.Phoenix Elixir.WeddingPlannerWeb Elixir.Plug)

  defp valuation_modules do
    {:ok, modules} = :application.get_key(:wedding_planner, :modules)

    Enum.filter(modules, fn module ->
      name = Atom.to_string(module)
      name == @namespace or String.starts_with?(name, @namespace <> ".")
    end)
  end

  # Every module name referenced anywhere in `module`'s compiled code: call targets,
  # struct names, and atoms nested inside literals.
  defp referenced_modules(module) do
    {:beam_file, ^module, _exports, _attributes, _compile_info, code} =
      :beam_disasm.file(:code.which(module))

    code
    |> collect_atoms(MapSet.new())
    |> Enum.map(&Atom.to_string/1)
    |> Enum.filter(&String.starts_with?(&1, "Elixir."))
    |> MapSet.new()
  end

  defp collect_atoms(atom, acc) when is_atom(atom), do: MapSet.put(acc, atom)
  defp collect_atoms(list, acc) when is_list(list), do: Enum.reduce(list, acc, &collect_atoms/2)

  defp collect_atoms(tuple, acc) when is_tuple(tuple),
    do: tuple |> Tuple.to_list() |> collect_atoms(acc)

  defp collect_atoms(%{} = map, acc), do: map |> Map.to_list() |> collect_atoms(acc)
  defp collect_atoms(_other, acc), do: acc

  defp offending(module, prefixes) do
    module
    |> referenced_modules()
    |> Enum.filter(fn name ->
      Enum.any?(prefixes, &(name == &1 or String.starts_with?(name, &1 <> ".")))
    end)
  end

  test "the scan covers the whole namespace (so the checks below are not vacuous)" do
    modules = valuation_modules()

    for expected <- [
          WeddingPlanner.Valuation,
          WeddingPlanner.Valuation.Snapshot,
          @loader,
          WeddingPlanner.Valuation.Formula,
          WeddingPlanner.Valuation.Formula.Step,
          WeddingPlanner.Valuation.Preset,
          WeddingPlanner.Valuation.Headcount,
          WeddingPlanner.Valuation.Offer,
          WeddingPlanner.Valuation.Budget,
          WeddingPlanner.Valuation.Selection,
          WeddingPlanner.Valuation.Gaps
        ] do
      assert expected in modules, "#{inspect(expected)} missing from the scan"
    end
  end

  test "the scanner does see database references where they exist (the loader's)" do
    assert "Elixir.Ecto.Query" in offending(@loader, @database)
  end

  test "no module but the snapshot loader references Repo or any query API" do
    violations =
      for module <- valuation_modules(),
          module != @loader,
          (refs = offending(module, @database)) != [],
          do: {module, refs}

    assert violations == [], "database access outside Snapshot.Loader: #{inspect(violations)}"
  end

  test "no module in the namespace references Phoenix or the web layer" do
    violations =
      for module <- valuation_modules(),
          (refs = offending(module, @web)) != [],
          do: {module, refs}

    assert violations == [], "web-layer references in the valuation layer: #{inspect(violations)}"
  end
end
