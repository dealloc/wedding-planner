defmodule WeddingPlanner.Transfer.ImportTest do
  @moduledoc """
  The import applier (`DR-93` (3)–(6), `DR-94`, `DR-97`, `DR-98`) over the rich fixture:
  round trip (FP-100a), replace-never-merge (FP-100b), refusals with nothing written
  (FP-100c/d/g), user remap (FP-100e, `DR-22`), the file swap (FP-100f), the safety copy
  and undo (FP-100h), the two-step person delete (FP-100i), the broadcast (FP-100j,
  `XC-01`), the one activity entry (FP-100k, `XC-10`), ids afterwards (FP-100l) and the
  `DR-79` markers (FP-100m).

  `:transfer_dir` and `:uploads_dir` point at the test's own tmp dir, so every file
  assertion is exact. Expected values come from the fixture or are literal, never from the
  code under test.
  """
  use WeddingPlanner.DataCase, async: false

  alias WeddingPlanner.Accounts.User
  alias WeddingPlanner.DemoSeedRun
  alias WeddingPlanner.Guests
  alias WeddingPlanner.Guests.Group
  alias WeddingPlanner.Guests.Person
  alias WeddingPlanner.Log
  alias WeddingPlanner.Log.Entry
  alias WeddingPlanner.Offers
  alias WeddingPlanner.Presets
  alias WeddingPlanner.Presets.HeadcountPreset
  alias WeddingPlanner.Realtime
  alias WeddingPlanner.ReferenceFixtures
  alias WeddingPlanner.References
  alias WeddingPlanner.References.Storage
  alias WeddingPlanner.Settings
  alias WeddingPlanner.Tasks
  alias WeddingPlanner.Tasks.Task
  alias WeddingPlanner.Transfer
  alias WeddingPlanner.Transfer.Document
  alias WeddingPlanner.Transfer.Export
  alias WeddingPlanner.Transfer.Import
  alias WeddingPlanner.Transfer.Tables
  alias WeddingPlanner.TransferFixtures

  @moduletag :tmp_dir

  @now ~U[2026-09-25 12:05:00Z]
  @host "localhost:4000"
  @zone "Europe/Brussels"

  setup %{tmp_dir: tmp_dir} do
    dirs = TransferFixtures.isolate_transfer_dirs!(tmp_dir)
    data = TransferFixtures.rich!()
    Map.merge(dirs, %{data: data, scope: data.scope, tmp_dir: tmp_dir})
  end

  # -- helpers -----------------------------------------------------------------------------

  defp export!, do: [now: @now, source_host: @host] |> Export.build() |> IO.iodata_to_binary()

  defp stash!(binary, tmp_dir) do
    path = Path.join(tmp_dir, "upload-#{System.unique_integer([:positive])}.json")
    File.write!(path, binary)
    {:ok, token} = Transfer.stash_upload(path)
    token
  end

  defp run_import(binary, scope, tmp_dir, opts \\ []) do
    token = stash!(binary, tmp_dir)

    result =
      Transfer.import(
        token,
        scope,
        Keyword.merge([origin: nil, time_zone: @zone, source_host: @host], opts)
      )

    {result, token}
  end

  defp import!(binary, scope, tmp_dir, opts \\ []) do
    {{:ok, result}, _token} = run_import(binary, scope, tmp_dir, opts)
    result
  end

  # Decodes an export, applies `fun` to the JSON term and re-encodes it (a hand-edited file).
  defp edit(binary, fun), do: binary |> Jason.decode!() |> fun.() |> Jason.encode!()

  defp update_rows(json, table, fun), do: update_in(json, ["tables", table], fun)

  defp without_meta(binary) when is_binary(binary),
    do: binary |> Jason.decode!() |> Map.delete("meta")

  # Every transferred table, row for row, straight from the database.
  defp db_snapshot do
    Map.new(Tables.transferred(), fn %{key: key, schema: schema} ->
      {key, Repo.all(from(s in schema, order_by: [asc: s.id]))}
    end)
  end

  defp upload_files(uploads_dir) do
    case File.ls(uploads_dir) do
      {:ok, names} ->
        Map.new(names, &{&1, File.read!(Path.join(uploads_dir, &1))})

      {:error, :enoent} ->
        %{}
    end
  end

  defp safety_copies(transfer_dir) do
    case File.ls(Path.join(transfer_dir, "safety-copies")) do
      {:ok, names} -> Enum.sort(names)
      {:error, :enoent} -> []
    end
  end

  defp snapshot(ctx) do
    %{
      db: db_snapshot(),
      uploads: upload_files(ctx.uploads_dir),
      safety_copies: safety_copies(ctx.transfer_dir)
    }
  end

  # A file reference created through the context, on an owner that exists in the export.
  defp add_file_reference!(scope, data, kind) do
    {:ok, reference} =
      References.create_file_reference(
        scope,
        Offers.reference_owner(data.offers.catering),
        %{"label" => "Extra #{System.unique_integer([:positive])}"},
        ReferenceFixtures.write_fixture!(ReferenceFixtures.tmp_upload_dir!(), kind, "x.pdf")
      )

    reference
  end

  defp delete_reference!(scope, data, reference) do
    owner =
      if reference.offer_id == data.offers.venue.id,
        do: Offers.reference_owner(data.offers.venue),
        else: Offers.reference_owner(data.offers.catering)

    {:ok, _} = References.delete_reference(scope, owner, reference)
  end

  defp assert_nothing_changed(before, ctx, token) do
    assert snapshot(ctx) == before
    assert safety_copies(ctx.transfer_dir) == []
    # The stash is kept until discard/1.
    assert File.regular?(Path.join([ctx.transfer_dir, "incoming", token <> ".json"]))
    assert :ok = Transfer.discard(token)
    refute File.exists?(Path.join([ctx.transfer_dir, "incoming", token <> ".json"]))
  end

  # A file whose one `invoice_lines` row points at a missing invoice (FP-100g).
  defp dangling_invoice_line(binary) do
    edit(binary, fn json ->
      update_rows(json, "invoice_lines", fn [first | rest] ->
        [Map.put(first, "invoice_id", 999_999) | rest]
      end)
    end)
  end

  # -- FP-100a -----------------------------------------------------------------------------

  describe "FP-100a round trip" do
    test "export A, change the app, import A, export B: B == A apart from meta and the one new entry",
         ctx do
      %{scope: scope, data: data} = ctx

      a = export!()
      a_json = Jason.decode!(a)

      # 98's coverage guard: every transferred table is non-empty in A.
      for %{key: key} <- Tables.transferred(),
          do: assert(a_json["tables"][key] != [], "#{key} is empty in A")

      # Make the app different: a host with a +1 deleted, a task added, the budget changed.
      {:ok, _} = Guests.delete_person(scope, data.persons.anna)
      {:ok, _} = Tasks.create_task(scope, %{"title" => "A task that must not survive"})
      {:ok, _} = Settings.update(scope, Settings.get(), %{"overall_budget_input" => "99000"})

      import!(a, scope, ctx.tmp_dir)
      b_json = Jason.decode!(export!())

      max_a_entry_id = a_json["tables"]["activity_entries"] |> Enum.map(& &1["id"]) |> Enum.max()

      {new_entries, b_entries} =
        Enum.split_with(b_json["tables"]["activity_entries"], &(&1["id"] > max_a_entry_id))

      assert [%{"description" => description}] = new_entries
      assert description == "Wannes imported data exported 25/09/2026 14:05 from localhost:4000"

      b_json = put_in(b_json, ["tables", "activity_entries"], b_entries)

      assert Map.delete(b_json, "meta") == Map.delete(a_json, "meta")
      assert b_json["files"] == a_json["files"]
      assert [%{"data_base64" => base64}] = b_json["files"]
      assert Base.decode64!(base64) == ReferenceFixtures.bytes(:pdf)
    end
  end

  # -- FP-100b -----------------------------------------------------------------------------

  describe "FP-100b replace, never merge" do
    test "rows absent from the file are gone; a row in both carries the file's values", ctx do
      %{scope: scope, data: data} = ctx
      a = export!()
      [family, _friends] = data.groups

      {:ok, extra_preset} =
        Presets.create_preset(scope, %{"name" => "A fourth preset", "want_tiers" => ["yes"]})

      {:ok, _} = Settings.update(scope, Settings.get(), %{"overall_budget_input" => "12345"})
      {:ok, _} = Guests.update_group(scope, family, %{"name" => "Renamed after export"})

      import!(a, scope, ctx.tmp_dir)

      refute Repo.get(HeadcountPreset, extra_preset.id)

      assert Money.compare(Settings.get().overall_budget, Money.new(:EUR, Decimal.new(45_000))) ==
               :eq

      assert Repo.get!(Group, family.id).name == "Family Peeters"

      assert Repo.aggregate(HeadcountPreset, :count) ==
               length(Jason.decode!(a)["tables"]["headcount_presets"])
    end
  end

  # -- FP-100c / FP-100d -------------------------------------------------------------------

  describe "FP-100c / FP-100d refused, nothing written" do
    setup %{scope: scope, data: data} do
      a = export!()
      # So the file carries an upload that isn't on disk: a refused import must not add it.
      delete_reference!(scope, data, data.references.file)
      %{a: a}
    end

    test "FP-100c a newer data version is :schema_mismatch and changes nothing", ctx do
      file = edit(ctx.a, &update_in(&1, ["meta", "schema_version"], fn v -> v + 1 end))
      before = snapshot(ctx)

      {result, token} = run_import(file, ctx.scope, ctx.tmp_dir)

      assert {:error, %{reason: :schema_mismatch}} = result
      assert_nothing_changed(before, ctx, token)
    end

    test "FP-100d a checksum mismatch is :malformed and changes nothing", ctx do
      file =
        edit(ctx.a, fn json ->
          update_in(json, ["files"], fn [f] ->
            [Map.put(f, "sha256", String.duplicate("0", 64))]
          end)
        end)

      before = snapshot(ctx)
      {result, token} = run_import(file, ctx.scope, ctx.tmp_dir)

      assert {:error, %{reason: :malformed, message: message}} = result
      assert message =~ "files[0]"
      assert_nothing_changed(before, ctx, token)
    end

    test "FP-100d invalid JSON is :malformed and changes nothing", ctx do
      before = snapshot(ctx)
      {result, token} = run_import("{\"format\": ", ctx.scope, ctx.tmp_dir)

      assert {:error, %{reason: :malformed}} = result
      assert_nothing_changed(before, ctx, token)
    end
  end

  # -- FP-100e -----------------------------------------------------------------------------

  describe "FP-100e user remap (DR-93 (2), DR-22)" do
    setup %{data: data, scope: wannes} do
      lotte = data.lotte

      # The file's users are "Wannes" (the fixture's author, who also owns the linked
      # task) and "Dev" (Lotte renamed: she owns a task and wrote one entry).
      file =
        edit(export!(), fn json ->
          json
          |> Map.put("users", [
            %{"id" => wannes.user.id, "display_name" => "Wannes"},
            %{"id" => lotte.id, "display_name" => "Dev"}
          ])
          |> update_rows("tasks", fn tasks ->
            Enum.map(tasks, fn task ->
              if task["id"] == data.tasks.linked.id,
                do: Map.put(task, "owner_id", wannes.user.id),
                else: task
            end)
          end)
          |> update_rows("activity_entries", fn [first | rest] ->
            [Map.put(first, "user_id", lotte.id) | rest]
          end)
        end)

      # This app's users: " wannes " and "Partner" (both with a passkey), and a
      # provisional "Dev" without one, who must not be matched (DR-22). The fixture's own
      # "Wannes" has no passkey, and Lotte is renamed so her name matches nothing.
      target_wannes = TransferFixtures.assignable_scope!(" wannes ").user
      partner = TransferFixtures.assignable_scope!("Partner")
      _provisional_dev = %User{} |> User.changeset(%{display_name: "Dev"}) |> Repo.insert!()
      lotte |> User.changeset(%{display_name: "Lotte (here)"}) |> Repo.update!()

      %{remap_file: file, target_wannes: target_wannes, partner: partner}
    end

    test "trimmed, case-folded unique match; no match maps to the importer", ctx do
      %{remap_file: file, target_wannes: target_wannes, partner: partner, data: data} = ctx
      token = stash!(file, ctx.tmp_dir)

      assert {:ok, preview} = Transfer.preview(token, partner)

      assert preview.users == [
               %{source_name: "Wannes", target_name: " wannes ", matched?: true},
               %{source_name: "Dev", target_name: "Partner", matched?: false}
             ]

      assert {:ok, _} =
               Transfer.import(token, partner, origin: nil, time_zone: @zone, source_host: @host)

      assert Repo.get!(Task, data.tasks.linked.id).owner_id == target_wannes.id
      assert Repo.get!(Task, data.tasks.owned.id).owner_id == partner.user.id

      [first_entry | _] = Repo.all(from(e in Entry, order_by: [asc: e.id]))
      assert first_entry.user_id == partner.user.id

      authors = Repo.all(from(e in Entry, select: e.user_id, distinct: true))
      assert Enum.sort(authors) == Enum.sort([target_wannes.id, partner.user.id])
    end

    test "two assignable users with the same name: ambiguous, so the importer", ctx do
      %{remap_file: file, partner: partner, data: data} = ctx
      _second = TransferFixtures.assignable_scope!("WANNES")
      token = stash!(file, ctx.tmp_dir)

      assert {:ok,
              %{users: [%{source_name: "Wannes", target_name: "Partner", matched?: false} | _]}} =
               Transfer.preview(token, partner)

      assert {:ok, _} =
               Transfer.import(token, partner, origin: nil, time_zone: @zone, source_host: @host)

      assert Repo.get!(Task, data.tasks.linked.id).owner_id == partner.user.id
    end
  end

  # -- FP-100f -----------------------------------------------------------------------------

  describe "FP-100f the file swap (DR-94)" do
    test "new files written, old-only files deleted, shared files untouched, unrelated files kept",
         ctx do
      %{scope: scope, data: data, uploads_dir: uploads_dir} = ctx

      # In the file: the fixture's PDF (kept on disk: "pre-existing") and a PNG whose
      # reference is deleted after the export (so the import must write it).
      png_reference = add_file_reference!(scope, data, :png)
      a = export!()
      delete_reference!(scope, data, png_reference)
      refute File.exists?(Storage.path_for(png_reference))

      # Old-only: a reference created after the export.
      old_only = add_file_reference!(scope, data, :jpeg)
      assert File.exists?(Storage.path_for(old_only))

      # Unrelated: a file nothing references (e.g. a concurrent upload not committed yet).
      unrelated = Path.join(uploads_dir, "AAAAAAAAAAAAAAAAAAAAAA.pdf")
      File.write!(unrelated, ReferenceFixtures.bytes(:pdf))

      shared = Storage.path_for(data.references.file)
      past = System.os_time(:second) - 86_400
      File.touch!(shared, past)

      result = import!(a, scope, ctx.tmp_dir)

      assert File.read!(Storage.path_for(png_reference)) == ReferenceFixtures.bytes(:png)
      refute File.exists?(Storage.path_for(old_only))
      assert File.read!(shared) == ReferenceFixtures.bytes(:pdf)
      assert File.stat!(shared, time: :posix).mtime == past
      assert File.read!(unrelated) == ReferenceFixtures.bytes(:pdf)
      assert %{files_written: 1, files_removed: 1} = result

      assert uploads_dir |> File.ls!() |> Enum.sort() ==
               Enum.sort([
                 Path.basename(shared),
                 Path.basename(Storage.path_for(png_reference)),
                 "AAAAAAAAAAAAAAAAAAAAAA.pdf"
               ])
    end

    test "a key on disk with different bytes is :file_conflict, before anything is written",
         ctx do
      %{scope: scope, data: data} = ctx
      png_reference = add_file_reference!(scope, data, :png)
      a = export!()
      delete_reference!(scope, data, png_reference)

      File.write!(Storage.path_for(data.references.file), "%PDF-1.7 different bytes")
      before = snapshot(ctx)

      {result, token} = run_import(a, scope, ctx.tmp_dir)

      assert {:error, %{reason: :file_conflict, detail: %{file_key: key}}} = result
      assert key == data.references.file.file_key
      assert_nothing_changed(before, ctx, token)
    end
  end

  # -- FP-100g -----------------------------------------------------------------------------

  describe "FP-100g failure consistency" do
    test "a dangling foreign key is :inconsistent; DB, files and safety copies as before", ctx do
      %{scope: scope, data: data, uploads_dir: uploads_dir} = ctx
      png_reference = add_file_reference!(scope, data, :png)
      file = dangling_invoice_line(export!())
      # The PNG must be written by phase 1, then removed again by the rollback.
      delete_reference!(scope, data, png_reference)
      old_only = add_file_reference!(scope, data, :jpeg)
      before = snapshot(ctx)

      {result, token} = run_import(file, scope, ctx.tmp_dir)

      assert {:error, %{reason: :inconsistent, message: message}} = result
      assert message =~ "invoice_lines"
      assert message =~ "invoices"
      refute File.exists?(Storage.path_for(png_reference))
      assert File.exists?(Storage.path_for(old_only))
      assert upload_files(uploads_dir) == before.uploads
      assert_nothing_changed(before, ctx, token)
    end
  end

  # -- FP-100h -----------------------------------------------------------------------------

  describe "FP-100h safety copy (DR-97)" do
    test "holds the pre-import state; importing it undoes the import", ctx do
      %{scope: scope, data: data} = ctx
      a = export!()

      {:ok, _} = Tasks.create_task(scope, %{"title" => "Only in the pre-import state"})
      {:ok, _} = Guests.delete_person(scope, data.persons.bram)
      pre = export!()

      result = import!(a, scope, ctx.tmp_dir, now: @now)
      assert result.safety_copy == "wedding-planner-before-import-25-09-2026-1405.json"

      assert [%{name: name, byte_size: size, saved_at: %DateTime{}}] =
               Transfer.list_safety_copies()

      assert name == result.safety_copy
      assert {:ok, path} = Transfer.safety_copy_path(name)
      copy = File.read!(path)
      assert size == byte_size(copy)
      assert {:ok, %Document{}} = Document.parse(copy)
      assert without_meta(copy) == without_meta(pre)

      # Undo: importing the safety copy brings the pre-import state back.
      undo = import!(copy, scope, ctx.tmp_dir, now: @now)
      assert undo.safety_copy == "wedding-planner-before-import-25-09-2026-1405-2.json"

      after_undo = Jason.decode!(export!())
      pre_json = Jason.decode!(pre)
      max_pre_id = pre_json["tables"]["activity_entries"] |> Enum.map(& &1["id"]) |> Enum.max()

      after_undo =
        update_rows(after_undo, "activity_entries", fn entries ->
          Enum.reject(entries, &(&1["id"] > max_pre_id))
        end)

      assert Map.delete(after_undo, "meta") == Map.delete(pre_json, "meta")

      assert Enum.map(Transfer.list_safety_copies(), & &1.name) == [
               "wedding-planner-before-import-25-09-2026-1405-2.json",
               "wedding-planner-before-import-25-09-2026-1405.json"
             ]
    end

    test "safety_copy_path/1 refuses anything but an existing well-formed name", ctx do
      import!(export!(), ctx.scope, ctx.tmp_dir, now: @now)
      # A real file one level up, so an unvalidated join of "../x" would find it.
      File.write!(Path.join(ctx.transfer_dir, "x"), "not a safety copy")

      assert {:ok, _} =
               Transfer.safety_copy_path("wedding-planner-before-import-25-09-2026-1405.json")

      assert :error = Transfer.safety_copy_path("../x")

      assert :error =
               Transfer.safety_copy_path(
                 "wedding-planner-before-import-25-09-2026-1405.json/../../x"
               )

      assert :error =
               Transfer.safety_copy_path("wedding-planner-before-import-01-01-2020-0000.json")

      assert :error = Transfer.safety_copy_path(nil)
    end
  end

  # -- FP-100i -----------------------------------------------------------------------------

  describe "FP-100i two-step person delete (DR-98)" do
    test "an app with +1s imports (the RESTRICT self-reference is deleted +1s first)", ctx do
      %{scope: scope} = ctx
      assert Repo.exists?(from(p in Person, where: not is_nil(p.host_id)))

      import!(export!(), scope, ctx.tmp_dir)

      assert Repo.aggregate(from(p in Person, where: not is_nil(p.host_id)), :count) == 2
    end
  end

  # -- FP-100j -----------------------------------------------------------------------------

  describe "FP-100j the :data_import broadcast (XC-01, DR-95)" do
    test "after a successful import, with the origin; nothing after a refused one", ctx do
      %{scope: scope} = ctx
      a = export!()
      :ok = Realtime.subscribe(:data_import)
      me = self()

      {{:error, %{reason: :inconsistent}}, _token} =
        run_import(dangling_invoice_line(a), scope, ctx.tmp_dir, origin: me)

      refute_receive {Realtime, :data_import, _}

      import!(a, scope, ctx.tmp_dir, origin: me)

      assert_receive {Realtime, :data_import,
                      {:created, %{origin: ^me, source_host: @host, exported_at: @now}}}
    end
  end

  # -- FP-100k -----------------------------------------------------------------------------

  describe "FP-100k the one activity entry (XC-10, DR-98)" do
    test "one entry beyond the file's, by the importer, no entity, id above every imported id",
         ctx do
      %{scope: scope} = ctx

      # A file from an installation with a longer history: its entry ids are far above
      # anything this app has handed out.
      file =
        edit(export!(), fn json ->
          update_rows(json, "activity_entries", fn entries ->
            Enum.map(entries, fn entry ->
              entry
              |> Map.update!("id", &(&1 + 10_000))
              |> Map.update!("parent_id", fn
                nil -> nil
                id -> id + 10_000
              end)
            end)
          end)
        end)

      file_ids =
        file |> Jason.decode!() |> get_in(["tables", "activity_entries"]) |> Enum.map(& &1["id"])

      import!(file, scope, ctx.tmp_dir)

      entries = Repo.all(from(e in Entry, order_by: [asc: e.id]))
      assert length(entries) == length(file_ids) + 1
      new = List.last(entries)

      assert new.id > Enum.max(file_ids)
      assert Enum.map(Enum.drop(entries, -1), & &1.id) == file_ids
      assert new.user_id == scope.user.id
      assert new.entity_type == nil and new.entity_id == nil and new.parent_id == nil

      assert new.description ==
               "Wannes imported data exported 25/09/2026 14:05 from localhost:4000"
    end

    test "no :activity_entry broadcast for it (the :data_import one covers readers)", ctx do
      a = export!()
      :ok = Realtime.subscribe(:activity_entry)
      import!(a, ctx.scope, ctx.tmp_dir)
      refute_receive {Realtime, :activity_entry, _}
    end
  end

  # -- FP-100l -----------------------------------------------------------------------------

  describe "FP-100l ids after an import" do
    test "new persons, tasks and entries get fresh ids", ctx do
      %{scope: scope} = ctx
      a_json = Jason.decode!(export!())
      import!(Jason.encode!(a_json), scope, ctx.tmp_dir)

      max_id = fn table -> a_json["tables"][table] |> Enum.map(& &1["id"]) |> Enum.max() end
      max_entry_id = Repo.one(from(e in Entry, select: max(e.id)))

      assert {:ok, person} =
               Guests.create_person(scope, %{"first_name" => "New", "last_name" => "Guest"})

      assert person.id > max_id.("persons")
      assert {:ok, task} = Tasks.create_task(scope, %{"title" => "New task"})
      assert task.id > max_id.("tasks")

      assert {:ok, entry} = Log.entry(scope, {:person, person.id}, "Wannes did something")
      assert entry.id > max_entry_id
    end
  end

  # -- FP-100m -----------------------------------------------------------------------------

  describe "FP-100m demo_seed_runs travel (DR-79)" do
    test "markers in the file are present afterwards", ctx do
      a = export!()
      Repo.delete_all(DemoSeedRun)
      import!(a, ctx.scope, ctx.tmp_dir)
      assert Repo.all(from(d in DemoSeedRun, select: d.name)) == ["transfer-fixture"]
    end

    test "a file without markers leaves none", ctx do
      file = edit(export!(), &put_in(&1, ["tables", "demo_seed_runs"], []))
      assert Repo.aggregate(DemoSeedRun, :count) == 1
      import!(file, ctx.scope, ctx.tmp_dir)
      assert Repo.aggregate(DemoSeedRun, :count) == 0
    end
  end

  # -- odds and ends -----------------------------------------------------------------------

  describe "settings" do
    test "a file without a settings row imports; Settings.get/0 recreates the singleton", ctx do
      file = edit(export!(), &put_in(&1, ["tables", "settings"], []))
      import!(file, ctx.scope, ctx.tmp_dir)

      assert %Settings{overall_budget: nil} = Settings.get()
    end
  end

  describe "result" do
    test "counts per shown kind, from the file", ctx do
      result = import!(export!(), ctx.scope, ctx.tmp_dir, now: @now)

      assert result.exported_at == @now
      assert result.source_host == @host
      refute Enum.any?(result.counts, &(&1.key == "demo_seed_runs"))
      assert %{label: "People", imported: 5} = Enum.find(result.counts, &(&1.key == "persons"))
      assert %{imported: 3} = Enum.find(result.counts, &(&1.key == "events"))
      assert %{imported: 2} = Enum.find(result.counts, &(&1.key == "groups"))
      assert %{imported: 3} = Enum.find(result.counts, &(&1.key == "tasks"))
      assert result.files_written == 0
      assert result.files_removed == 0
    end

    test "a successful import discards the stash; a second import of the token is :expired",
         ctx do
      {{:ok, _}, token} = run_import(export!(), ctx.scope, ctx.tmp_dir)

      assert {:error, %{reason: :expired}} =
               Transfer.import(token, ctx.scope,
                 origin: nil,
                 time_zone: @zone,
                 source_host: @host
               )
    end
  end

  describe "refusal_for/1" do
    test "a busy or locked database is :busy; another database error :inconsistent" do
      assert %{reason: :busy, message: "The other user was saving at that moment — try again."} =
               Import.refusal_for(%Exqlite.Error{message: "database is locked"})

      assert %{reason: :busy} = Import.refusal_for(%Exqlite.Error{message: "Database busy"})

      assert %{reason: :inconsistent} =
               Import.refusal_for(%Exqlite.Error{message: "UNIQUE constraint failed: groups.id"})

      assert %{reason: :storage} = Import.refusal_for(%RuntimeError{message: "boom"})
    end
  end
end
