defmodule WeddingPlanner.Transfer.ExportTest do
  @moduledoc """
  The export over the rich fixture (`DR-93` (1), `DR-96`): fidelity of every row and file
  through `Export.build/1` → `Document.parse/1` (FP-98h), exclusions (FP-98i),
  determinism and missing files (FP-98j), lossless money (FP-98e, the file half) and the
  header and key order (`Jason.OrderedObject`). Expected JSON values are literal.
  """
  use WeddingPlanner.DataCase, async: false

  import ExUnit.CaptureLog

  alias WeddingPlanner.Offers.OfferLine
  alias WeddingPlanner.References.Storage
  alias WeddingPlanner.TransferFixtures
  alias WeddingPlanner.Transfer.Document
  alias WeddingPlanner.Transfer.Export
  alias WeddingPlanner.Transfer.SchemaVersion
  alias WeddingPlanner.Transfer.Tables

  @now ~U[2026-09-25 12:05:00Z]

  setup do
    %{data: TransferFixtures.rich!()}
  end

  defp build!(opts \\ []) do
    [now: @now, source_host: "localhost:4000"]
    |> Keyword.merge(opts)
    |> Export.build()
    |> IO.iodata_to_binary()
  end

  defp money_field?(schema, field),
    do: Ecto.Type.type(schema.__schema__(:type, field)) == :map

  describe "FP-98h fidelity over the rich fixture" do
    test "every transferred table has at least one row (so the round trip covers all)" do
      empty =
        for %{key: key, schema: schema} <- Tables.transferred(),
            Repo.aggregate(schema, :count) == 0,
            do: key

      assert empty == []

      # The self-references and arrays the applier must carry are really exercised.
      assert Repo.exists?(from(e in WeddingPlanner.Log.Entry, where: not is_nil(e.parent_id)))
      assert Repo.exists?(from(p in WeddingPlanner.Guests.Person, where: not is_nil(p.host_id)))
      assert Repo.exists?(from(t in WeddingPlanner.Tasks.Task, where: not is_nil(t.owner_id)))

      assert Repo.exists?(
               from(p in WeddingPlanner.Presets.HeadcountPreset,
                 where: fragment("json_array_length(?)", p.group_ids) > 0
               )
             )

      statuses = Repo.all(from(i in WeddingPlanner.Invitations.Invitation, select: i.status))

      assert Enum.sort(Enum.uniq(statuses)) ==
               Enum.sort([:planned, :invited, :accepted, :declined])
    end

    test "parsed rows equal Repo.all of each schema, field by field", %{data: _data} do
      assert {:ok, %Document{} = document} = Document.parse(build!())
      assert Enum.map(document.tables, fn {entry, _rows} -> entry end) == Tables.transferred()

      for {%{key: key, schema: schema}, rows} <- document.tables do
        stored = Repo.all(from(s in schema, order_by: [asc: s.id]))
        assert length(rows) == length(stored), key

        for {row, struct} <- Enum.zip(rows, stored), field <- schema.__schema__(:fields) do
          expected = Map.fetch!(struct, field)
          actual = Map.fetch!(row, field)

          if money_field?(schema, field) and not is_nil(expected) do
            assert %Money{} = actual, "#{key}.#{field}"
            assert Money.compare(actual, expected) == :eq, "#{key}.#{field}"
          else
            assert actual == expected, "#{key}[id #{struct.id}].#{field}"
          end
        end

        assert Enum.map(rows, &Map.keys/1) |> Enum.uniq() |> Enum.map(&Enum.sort/1) ==
                 [Enum.sort(schema.__schema__(:fields))]
      end

      assert Document.counts(document) ==
               Map.new(Tables.transferred(), &{&1.key, Repo.aggregate(&1.schema, :count)})
    end

    test "embedded files equal the bytes on disk", %{data: data} do
      reference = data.references.file
      {:ok, document} = Document.parse(build!())

      assert document.files == %{
               reference.file_key => %{
                 content_type: "application/pdf",
                 bytes: File.read!(Storage.path_for(reference))
               }
             }

      assert document.meta.missing_files == []
    end

    test "the cleared amount ('null' text, DR-45) and the never-set one both parse as nil",
         %{data: data} do
      cleared_id = data.lines.cleared.id
      precise_id = data.lines.precise.id

      # The fixture really produced both storage forms.
      assert %{rows: [["null", nil]]} =
               Repo.query!("SELECT amount, minimum_charge FROM offer_lines WHERE id = ?", [
                 cleared_id
               ])

      assert %{rows: [[nil]]} =
               Repo.query!("SELECT minimum_charge FROM offer_lines WHERE id = ?", [precise_id])

      {:ok, document} = Document.parse(build!())
      {_entry, lines} = Enum.find(document.tables, fn {entry, _} -> entry.schema == OfferLine end)

      assert %{amount: nil, minimum_charge: nil} = Enum.find(lines, &(&1.id == cleared_id))
      assert %{minimum_charge: nil} = Enum.find(lines, &(&1.id == precise_id))

      json = Jason.decode!(build!())
      cleared = Enum.find(json["tables"]["offer_lines"], &(&1["id"] == cleared_id))
      assert cleared["amount"] == nil
      assert cleared["minimum_charge"] == nil
    end
  end

  describe "FP-98e money in the file" do
    test "the 7641.4999999999999999 line is exactly that string and decodes losslessly",
         %{data: data} do
      precise_id = data.lines.precise.id
      json = Jason.decode!(build!())
      line = Enum.find(json["tables"]["offer_lines"], &(&1["id"] == precise_id))

      assert line["amount"] == %{"amount" => "7641.4999999999999999", "currency" => "EUR"}

      assert hd(json["tables"]["settings"])["overall_budget"] == %{
               "amount" => "45000",
               "currency" => "EUR"
             }

      {:ok, document} = Document.parse(build!())
      {_entry, lines} = Enum.find(document.tables, fn {entry, _} -> entry.schema == OfferLine end)
      %{amount: %Money{} = amount} = Enum.find(lines, &(&1.id == precise_id))

      assert Money.compare(amount, Money.new(:EUR, Decimal.new("7641.4999999999999999"))) == :eq
    end
  end

  describe "FP-98i exclusions" do
    test "no passkey, session or enrollment data and no passkey name anywhere" do
      binary = build!()

      for forbidden <- [
            "credential_id",
            "public_key",
            ~s("token"),
            "passkeys",
            "user_sessions",
            "enrollment_links",
            "schema_migrations",
            "money_probes",
            TransferFixtures.secret_passkey_name()
          ] do
        refute binary =~ forbidden, "the export contains #{inspect(forbidden)}"
      end
    end

    test "users carry only id and display name", %{data: data} do
      json = Jason.decode!(build!())

      assert json["users"] == [
               %{"id" => data.scope.user.id, "display_name" => "Wannes"},
               %{"id" => data.lotte.id, "display_name" => "Lotte"}
             ]
    end
  end

  describe "FP-98j determinism and missing files" do
    test "two builds of the same data give identical bytes" do
      assert build!(source_host: "x") == build!(source_host: "x")
    end

    test "a missing upload is listed in missing_files without failing the export",
         %{data: data} do
      reference = data.references.file
      File.rm!(Storage.path_for(reference))

      {binary, log} = with_log(fn -> build!() end)

      assert log =~ "missing_files"
      json = Jason.decode!(binary)
      assert json["meta"]["missing_files"] == [reference.file_key]
      assert json["files"] == []

      # …and the damaged export can still be re-imported as is.
      assert {:ok, document} = Document.parse(binary)
      assert document.meta.missing_files == [reference.file_key]
      assert document.files == %{}
    end
  end

  describe "document shape" do
    test "the header is literal and the document term is exactly the decoded JSON", %{data: _} do
      opts = [now: @now, source_host: "localhost:4000"]
      json = Jason.decode!(build!())

      assert json["format"] == "wedding-planner-transfer"
      assert json["format_version"] == 1

      assert json["meta"] == %{
               "schema_version" => SchemaVersion.current(),
               "exported_at" => "2026-09-25T12:05:00Z",
               "source_host" => "localhost:4000",
               "missing_files" => []
             }

      assert Export.document(opts) == json
    end

    test "keys are in layout, registry and field order; rows by id", %{data: data} do
      json = Jason.decode!(build!(), objects: :ordered_objects)

      assert Enum.map(json.values, &elem(&1, 0)) ==
               ~w(format format_version meta users tables files)

      assert Enum.map(json["meta"].values, &elem(&1, 0)) ==
               ~w(schema_version exported_at source_host missing_files)

      assert Enum.map(json["tables"].values, &elem(&1, 0)) ==
               ~w(settings groups events persons invitations plus_one_opt_outs
                  headcount_presets categories services offers offer_lines offer_overrides
                  offer_frozen_services invoices invoice_lines references tasks
                  task_dependencies activity_entries demo_seed_runs)

      [event | _] = events = json["tables"]["events"]

      assert Enum.map(event.values, &elem(&1, 0)) ==
               ~w(id name date location sort_order notes couple_attends inserted_at updated_at)

      assert Enum.map(events, & &1["id"]) == Enum.sort(Enum.map(events, & &1["id"]))

      [file] = json["files"]

      assert Enum.map(file.values, &elem(&1, 0)) ==
               ~w(file_key content_type byte_size sha256 data_base64)

      pdf = WeddingPlanner.ReferenceFixtures.bytes(:pdf)
      assert file["file_key"] == data.references.file.file_key
      assert file["byte_size"] == byte_size(pdf)
      assert file["sha256"] == :crypto.hash(:sha256, pdf) |> Base.encode16(case: :lower)
      assert file["data_base64"] == Base.encode64(pdf)
      assert Enum.find(json["tables"]["events"], &(&1["name"] == "Brunch"))["date"] == nil

      assert Enum.find(json["tables"]["events"], &(&1["name"] == "Dinner"))["date"] ==
               "2027-06-12"
    end

    test "re-encoding the decoded JSON gives the same bytes" do
      binary = build!()
      assert binary |> Jason.decode!() |> Document.encode() |> IO.iodata_to_binary() == binary
    end

    test "works inside a caller's transaction (DR-98)" do
      assert {:ok, binary} = Repo.transaction(fn -> build!() end)
      assert {:ok, _document} = Document.parse(binary)
    end
  end
end
