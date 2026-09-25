defmodule WeddingPlanner.Transfer.TransferTest do
  @moduledoc """
  The `WeddingPlanner.Transfer` façade around the import (`DR-93` (5), (7), (8), `DR-97`):
  the preview (writes nothing, shown kinds only, files and users), the stash (size limit,
  expiry, sweep, discard), the limit shared with the parser, and the export filename.
  """
  use WeddingPlanner.DataCase, async: false

  alias WeddingPlanner.Guests
  alias WeddingPlanner.ReferenceFixtures
  alias WeddingPlanner.Tasks
  alias WeddingPlanner.Transfer
  alias WeddingPlanner.Transfer.Document
  alias WeddingPlanner.Transfer.Export
  alias WeddingPlanner.Transfer.Tables
  alias WeddingPlanner.TransferFixtures

  @moduletag :tmp_dir

  @now ~U[2026-09-25 12:05:00Z]

  setup %{tmp_dir: tmp_dir} do
    TransferFixtures.isolate_transfer_dirs!(tmp_dir)
  end

  defp stash!(binary, tmp_dir) do
    path = Path.join(tmp_dir, "upload-#{System.unique_integer([:positive])}.json")
    File.write!(path, binary)
    {:ok, token} = Transfer.stash_upload(path)
    token
  end

  defp export!,
    do: [now: @now, source_host: "localhost:4000"] |> Export.build() |> IO.iodata_to_binary()

  defp db_snapshot do
    Map.new(Tables.transferred(), fn %{key: key, schema: schema} ->
      {key, Repo.all(from(s in schema, order_by: [asc: s.id]))}
    end)
  end

  describe "preview/2" do
    setup %{tmp_dir: tmp_dir} do
      data = TransferFixtures.rich!()
      TransferFixtures.add_passkey!(data.scope.user)
      a = export!()

      # Here now: one person fewer, one task more.
      {:ok, _} = Guests.delete_person(data.scope, data.persons.bram)
      {:ok, _} = Tasks.create_task(data.scope, %{"title" => "Extra"})

      %{data: data, token: stash!(a, tmp_dir)}
    end

    test "counts, header, files and users; writes nothing", %{data: data, token: token} do
      before = db_snapshot()

      assert {:ok, preview} = Transfer.preview(token, data.scope)

      assert db_snapshot() == before

      assert File.ls(Application.fetch_env!(:wedding_planner, :transfer_dir)) ==
               {:ok, ["incoming"]}

      assert preview.exported_at == @now
      assert preview.source_host == "localhost:4000"
      assert preview.schema_version == WeddingPlanner.Transfer.SchemaVersion.current()
      assert preview.missing_files == 0

      # Every shown kind, registry order; the DR-79 markers travel but aren't shown.
      assert Enum.map(preview.counts, & &1.key) == ~w(
               settings groups events persons invitations plus_one_opt_outs headcount_presets
               categories services offers offer_lines offer_overrides offer_frozen_services
               invoices invoice_lines references tasks task_dependencies activity_entries
             )

      by_key = Map.new(preview.counts, &{&1.key, &1})
      assert %{label: "People", in_file: 5, here_now: 4} = by_key["persons"]
      assert %{label: "Tasks", in_file: 3, here_now: 4} = by_key["tasks"]
      assert %{in_file: 3, here_now: 3} = by_key["events"]
      assert %{in_file: 2, here_now: 2} = by_key["groups"]

      pdf = ReferenceFixtures.bytes(:pdf)
      assert preview.files == %{in_file: 1, in_file_bytes: byte_size(pdf), here_now: 1}

      assert preview.users == [
               %{source_name: "Wannes", target_name: "Wannes", matched?: true},
               %{source_name: "Lotte", target_name: "Lotte", matched?: true}
             ]
    end

    test "counts missing files", %{data: data, tmp_dir: tmp_dir} do
      File.rm!(WeddingPlanner.References.Storage.path_for(data.references.file))
      {binary, _log} = ExUnit.CaptureLog.with_log(&export!/0)
      token = stash!(binary, tmp_dir)

      assert {:ok, %{missing_files: 1, files: %{in_file: 0, in_file_bytes: 0}}} =
               Transfer.preview(token, data.scope)
    end

    test "an unknown, malformed or discarded token is :expired", %{data: data, token: token} do
      message = "That upload has expired — choose the file again."
      unknown = String.duplicate("A", 32)

      assert {:error, %{reason: :expired, message: ^message}} =
               Transfer.preview(unknown, data.scope)

      assert {:error, %{reason: :expired}} = Transfer.preview("../../etc/passwd", data.scope)

      assert :ok = Transfer.discard(token)
      assert {:error, %{reason: :expired}} = Transfer.preview(token, data.scope)
      assert :ok = Transfer.discard(token)
    end

    test "a file that doesn't parse is the parser's refusal", %{data: data, tmp_dir: tmp_dir} do
      token = stash!(~s({"format": "something else"}), tmp_dir)
      assert {:error, %{reason: :wrong_format}} = Transfer.preview(token, data.scope)
    end
  end

  describe "stash_upload/1" do
    test "max_upload_bytes/0 is 50 MB, the parser's own limit (DR-97)" do
      assert Transfer.max_upload_bytes() == 50_000_000
      assert Transfer.max_upload_bytes() == Document.max_bytes()
    end

    test "a file over the limit is :too_large and nothing is stashed", %{tmp_dir: tmp_dir} do
      path = Path.join(tmp_dir, "big.json")
      # Sparse: 50 000 001 bytes that cost nothing to write.
      {:ok, fd} = :file.open(path, [:write, :raw, :binary])
      {:ok, _} = :file.position(fd, Transfer.max_upload_bytes())
      :ok = :file.write(fd, "x")
      :ok = :file.close(fd)
      assert File.stat!(path).size == 50_000_001

      assert {:error, %{reason: :too_large, message: "This file is larger than 50 MB."}} =
               Transfer.stash_upload(path)

      incoming = Path.join(Application.fetch_env!(:wedding_planner, :transfer_dir), "incoming")
      assert File.ls(incoming) in [{:ok, []}, {:error, :enoent}]
    end

    test "copies (never moves) the upload under a 32-character token", %{tmp_dir: tmp_dir} do
      path = Path.join(tmp_dir, "upload.json")
      File.write!(path, "{}")

      assert {:ok, token} = Transfer.stash_upload(path)
      assert token =~ ~r/\A[A-Za-z0-9_-]{32}\z/
      assert File.read!(path) == "{}"

      stashed =
        Path.join([
          Application.fetch_env!(:wedding_planner, :transfer_dir),
          "incoming",
          token <> ".json"
        ])

      assert File.read!(stashed) == "{}"
    end

    test "a missing upload is a refusal, not a crash", %{tmp_dir: tmp_dir} do
      assert {:error, %{reason: :storage}} = Transfer.stash_upload(Path.join(tmp_dir, "nope"))
    end

    test "stashes older than an hour are swept on the next stash", %{tmp_dir: tmp_dir} do
      old = stash!("{}", tmp_dir)
      fresh = stash!("{}", tmp_dir)
      incoming = Path.join(Application.fetch_env!(:wedding_planner, :transfer_dir), "incoming")
      File.touch!(Path.join(incoming, old <> ".json"), System.os_time(:second) - 3_601)

      newest = stash!("{}", tmp_dir)

      assert incoming |> File.ls!() |> Enum.sort() ==
               Enum.sort([fresh <> ".json", newest <> ".json"])
    end
  end

  describe "export/1 and export_filename/2" do
    test "the filename is in the viewer's zone, dd-mm-yyyy-hhmm" do
      assert Transfer.export_filename(~U[2026-09-25 12:05:00Z], "Europe/Brussels") ==
               "wedding-planner-25-09-2026-1405.json"

      assert Transfer.export_filename(~U[2026-01-05 23:30:00Z], "Europe/Brussels") ==
               "wedding-planner-06-01-2026-0030.json"
    end

    test "export/1 is a parseable document of this app" do
      binary = [source_host: "wedding.example.com"] |> Transfer.export() |> IO.iodata_to_binary()

      assert {:ok, %Document{meta: %{source_host: "wedding.example.com"}}} =
               Document.parse(binary)
    end
  end

  describe "list_safety_copies/0" do
    test "empty when there are none" do
      assert Transfer.list_safety_copies() == []
    end

    test "only well-formed regular files, newest first" do
      dir = Path.join(Application.fetch_env!(:wedding_planner, :transfer_dir), "safety-copies")
      File.mkdir_p!(dir)
      older = "wedding-planner-before-import-01-09-2026-0900.json"
      newer = "wedding-planner-before-import-02-09-2026-0900.json"
      File.write!(Path.join(dir, older), "{}")
      File.write!(Path.join(dir, newer), "{\"x\": 1}")
      File.touch!(Path.join(dir, older), System.os_time(:second) - 100)
      File.write!(Path.join(dir, "notes.txt"), "no")
      File.write!(Path.join(dir, newer <> ".part"), "no")
      File.mkdir_p!(Path.join(dir, "wedding-planner-before-import-03-09-2026-0900.json"))

      assert [%{name: ^newer, byte_size: 8}, %{name: ^older, byte_size: 2, saved_at: saved_at}] =
               Transfer.list_safety_copies()

      assert_in_delta DateTime.to_unix(saved_at), System.os_time(:second) - 100, 2

      assert :error =
               Transfer.safety_copy_path("wedding-planner-before-import-03-09-2026-0900.json")

      assert {:ok, _} = Transfer.safety_copy_path(older)
    end
  end
end
