defmodule WeddingPlanner.Transfer.TripwireTest do
  @moduledoc """
  `DR-96`'s four tripwires, so a future table, column, field type or user reference
  can't silently fall out of the transfer file (`DR-93` (1), (2)):

    * (i) the SQLite tables equal transferred ∪ excluded (FP-98a);
    * (ii) every transferred table's columns equal its schema's field sources, with a
      permanent negative test (FP-98b);
    * (iii) every transferred field has a type the codec carries (FP-98c);
    * (iv) every `belongs_to … User` in a transferred schema is a listed user reference
      (FP-98d).

  Plus the data version (`WeddingPlanner.Transfer.SchemaVersion`) against the migration
  files on disk. Oracles are literal lists or read straight from SQLite, never from the
  registry under test.
  """
  use WeddingPlanner.DataCase, async: false

  alias WeddingPlanner.Accounts.User
  alias WeddingPlanner.Log.Entry
  alias WeddingPlanner.Guests.Person
  alias WeddingPlanner.Tasks.Task
  alias WeddingPlanner.Transfer.Codec
  alias WeddingPlanner.Transfer.SchemaVersion
  alias WeddingPlanner.Transfer.Tables

  # The 20 transferred tables, parents first (DR-93 (1)), written out literally.
  @expected_keys ~w(settings groups events persons invitations plus_one_opt_outs
                    headcount_presets categories services offers offer_lines offer_overrides
                    offer_frozen_services invoices invoice_lines references tasks
                    task_dependencies activity_entries demo_seed_runs)

  @expected_excluded ~w(users passkeys user_sessions enrollment_links schema_migrations money_probes)

  describe "FP-98a table tripwire (DR-96 (i))" do
    test "the SQLite tables equal exactly transferred ∪ excluded" do
      transferred = Enum.map(Tables.transferred(), & &1.key)
      excluded = Enum.map(Tables.excluded(), & &1.table)

      assert MapSet.disjoint?(MapSet.new(transferred), MapSet.new(excluded))

      assert sqlite_tables() == MapSet.new(transferred ++ excluded),
             "a table is neither transferred nor excluded: add it to " <>
               "WeddingPlanner.Transfer.Tables (DR-93). Found #{inspect(MapSet.to_list(sqlite_tables()))}"
    end

    test "the registry is the 20 tables in parents-first order, the exclusions the 6 of DR-93" do
      assert Enum.map(Tables.transferred(), & &1.key) == @expected_keys
      assert Enum.sort(Enum.map(Tables.excluded(), & &1.table)) == Enum.sort(@expected_excluded)
      assert Enum.all?(Tables.excluded(), &(is_binary(&1.reason) and &1.reason != ""))
    end

    test "only demo_seed_runs is hidden from the preview, and every entry has a label" do
      assert for(%{preview?: false, key: key} <- Tables.transferred(), do: key) == [
               "demo_seed_runs"
             ]

      assert Enum.all?(Tables.transferred(), &(is_binary(&1.label) and &1.label != ""))
    end

    test "every foreign key points at a table earlier in the registry (insert order)" do
      keys = Enum.map(Tables.transferred(), & &1.key)

      violations =
        for {%{key: key, schema: schema}, position} <- Enum.with_index(Tables.transferred()),
            assoc <- schema.__schema__(:associations),
            %Ecto.Association.BelongsTo{related: related} <- [
              schema.__schema__(:association, assoc)
            ],
            related not in [schema, User],
            parent <- [related.__schema__(:source)],
            Enum.find_index(keys, &(&1 == parent)) > position,
            do: {key, parent}

      assert violations == []
    end
  end

  describe "FP-98b column tripwire (DR-96 (ii))" do
    test "every transferred table's columns equal its schema's field sources" do
      assert column_mismatches() == []
    end

    test "negative: a column added without a schema field is reported" do
      Repo.query!("ALTER TABLE events ADD COLUMN transfer_tripwire_probe TEXT")

      assert column_mismatches() == [
               %{table: "events", unexpected: ["transfer_tripwire_probe"], missing: []}
             ]
    end
  end

  describe "FP-98c type tripwire (DR-96 (iii))" do
    test "every field of every transferred schema has a codec" do
      unsupported =
        for %{schema: schema} <- Tables.transferred(),
            field <- schema.__schema__(:fields),
            not Codec.supported?({schema, field}),
            do: {schema, field, schema.__schema__(:type, field)}

      assert unsupported == []
    end
  end

  describe "FP-98d user-reference tripwire (DR-96 (iv))" do
    test "every belongs_to User in a transferred schema is a listed user reference" do
      found =
        for %{schema: schema} <- Tables.transferred(),
            assoc <- schema.__schema__(:associations),
            %Ecto.Association.BelongsTo{related: User, owner_key: key} <-
              [schema.__schema__(:association, assoc)],
            into: MapSet.new(),
            do: {schema, key}

      assert found == MapSet.new(Tables.user_references())

      assert Enum.sort(Tables.user_references()) ==
               Enum.sort([{Task, :owner_id}, {Entry, :user_id}, {Person, :witness_of_id}])
    end
  end

  describe "SchemaVersion.current/0 (DR-93 (1))" do
    test "is the newest migration on disk, and at least the W14 one" do
      newest_file =
        "priv/repo/migrations/*.exs"
        |> Path.wildcard()
        |> Enum.map(fn path ->
          path |> Path.basename() |> String.split("_") |> hd() |> String.to_integer()
        end)
        |> Enum.max()

      assert SchemaVersion.current() == newest_file
      assert SchemaVersion.current() >= 20_260_924_124_144
    end

    test "agrees with Ecto.Migrator's newest :up migration" do
      newest_up =
        for {:up, version, _name} <- Ecto.Migrator.migrations(Repo), reduce: 0 do
          acc -> max(acc, version)
        end

      assert SchemaVersion.current() == newest_up
    end
  end

  # -- helpers -----------------------------------------------------------------------------

  defp sqlite_tables do
    Repo.query!(
      "SELECT name FROM sqlite_master WHERE type = 'table' AND name NOT LIKE 'sqlite_%'"
    ).rows
    |> List.flatten()
    |> MapSet.new()
  end

  # For every transferred table whose columns differ from its schema's field sources:
  # the columns SQLite has that the schema lacks (`unexpected`) and the reverse (`missing`).
  defp column_mismatches do
    Enum.flat_map(Tables.transferred(), fn %{key: key, schema: schema} ->
      columns = Repo.query!(~s[PRAGMA table_info("#{key}")]).rows |> Enum.map(&Enum.at(&1, 1))

      sources =
        Enum.map(
          schema.__schema__(:fields),
          &Atom.to_string(schema.__schema__(:field_source, &1))
        )

      unexpected = Enum.sort(columns -- sources)
      missing = Enum.sort(sources -- columns)

      if unexpected == [] and missing == [],
        do: [],
        else: [%{table: key, unexpected: unexpected, missing: missing}]
    end)
  end
end
