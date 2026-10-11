defmodule WeddingPlanner.Transfer.DocumentTest do
  @moduledoc """
  `Document.parse/1`'s refusals (`DR-93` (4), `DR-96`): the schema-version check both ways
  and before any row (FP-98f), and the malformed catalogue (FP-98g), each case built by
  editing the decoded JSON of a valid export of the rich fixture and re-encoding it. Every
  malformed message must name its location.
  """
  use WeddingPlanner.DataCase, async: false

  alias WeddingPlanner.ReferenceFixtures
  alias WeddingPlanner.TransferFixtures
  alias WeddingPlanner.Transfer.Document
  alias WeddingPlanner.Transfer.Export
  alias WeddingPlanner.Transfer.Refusal
  alias WeddingPlanner.Transfer.SchemaVersion

  setup do
    data = TransferFixtures.rich!()

    binary =
      [now: ~U[2026-09-25 12:05:00Z], source_host: "localhost:4000"]
      |> Export.build()
      |> IO.iodata_to_binary()

    %{data: data, binary: binary, json: Jason.decode!(binary)}
  end

  defp encode(json), do: json |> Document.encode() |> IO.iodata_to_binary()

  defp parse_edited(json, fun), do: json |> fun.() |> encode() |> Document.parse()

  defp assert_malformed(result, location_and_problem) do
    assert {:error, %Refusal{reason: :malformed, message: message, detail: detail}} = result
    assert message == "This file is damaged: #{location_and_problem}."
    assert is_list(detail.path)
    message
  end

  defp update_row(json, table, index, fun),
    do: update_in(json, ["tables", table], &List.update_at(&1, index, fun))

  defp file_reference_index(json),
    do: Enum.find_index(json["tables"]["references"], &(&1["kind"] == "file"))

  defp file_entry(bytes, content_type, key) do
    %{
      "file_key" => key,
      "content_type" => content_type,
      "byte_size" => byte_size(bytes),
      "sha256" => :crypto.hash(:sha256, bytes) |> Base.encode16(case: :lower),
      "data_base64" => Base.encode64(bytes)
    }
  end

  test "a valid export parses, with counts per table", %{binary: binary, data: data} do
    assert {:ok, %Document{} = document} = Document.parse(binary)
    assert document.meta.format_version == 1
    assert document.meta.schema_version == SchemaVersion.current()
    assert document.meta.exported_at == ~U[2026-09-25 12:05:00Z]
    assert document.meta.source_host == "localhost:4000"

    assert document.users == [
             %{id: data.scope.user.id, display_name: "Wannes"},
             %{id: data.lotte.id, display_name: "Lotte"}
           ]

    assert Document.counts(document)["events"] == 3
    assert Document.counts(document)["demo_seed_runs"] == 1
    assert map_size(Document.counts(document)) == 23
  end

  test "a file over the size limit is :too_large", %{binary: binary} do
    assert {:error, %Refusal{reason: :too_large}} = Document.parse(binary, max_bytes: 100)
    assert Document.max_bytes() == 50_000_000
  end

  describe "FP-98f schema version" do
    test "an older file says to update the app it was exported from", %{json: json} do
      app = SchemaVersion.current()

      assert {:error, %Refusal{reason: :schema_mismatch, message: message, detail: detail}} =
               parse_edited(json, &put_in(&1, ["meta", "schema_version"], app - 1))

      assert message =~ "Update the app you exported from"
      assert message =~ "data version #{app - 1}; this app is at #{app}"
      assert detail == %{file: app - 1, app: app}
    end

    test "a newer file says to update this app first", %{json: json} do
      app = SchemaVersion.current()

      assert {:error, %Refusal{reason: :schema_mismatch, message: message}} =
               parse_edited(json, &put_in(&1, ["meta", "schema_version"], app + 1))

      assert message =~ "Update this app first"
    end

    test "a wrong version wins over a damaged row (checked before any row)", %{json: json} do
      assert {:error, %Refusal{reason: :schema_mismatch}} =
               parse_edited(json, fn json ->
                 json
                 |> put_in(["meta", "schema_version"], SchemaVersion.current() - 1)
                 |> update_row("offers", 0, &Map.put(&1, "status", "maybe"))
               end)
    end
  end

  describe "FP-98g malformed catalogue" do
    test "invalid JSON and a top-level array" do
      for binary <- ["{not json", "[1, 2]", ""] do
        assert {:error,
                %Refusal{
                  reason: :malformed,
                  message: "This file can't be read: it isn't valid JSON."
                }} =
                 Document.parse(binary)
      end
    end

    test "a wrong format is :wrong_format", %{json: json} do
      assert {:error,
              %Refusal{
                reason: :wrong_format,
                message: "This file isn't a wedding planner export."
              }} =
               parse_edited(json, &Map.put(&1, "format", "something-else"))

      assert {:error, %Refusal{reason: :wrong_format}} = Document.parse(~s({"hello": 1}))
    end

    test "format_version 2 is :unsupported_format_version; 0 is malformed", %{json: json} do
      assert {:error, %Refusal{reason: :unsupported_format_version, message: message}} =
               parse_edited(json, &Map.put(&1, "format_version", 2))

      assert message ==
               "This export uses file format 2, which this version of the app can't read. Update this app first."

      assert_malformed(
        parse_edited(json, &Map.put(&1, "format_version", 0)),
        "format_version must be 1"
      )
    end

    test "a missing table", %{json: json} do
      assert_malformed(
        parse_edited(json, &update_in(&1, ["tables"], fn t -> Map.delete(t, "events") end)),
        "tables.events is missing"
      )
    end

    test "an unknown table", %{json: json} do
      assert_malformed(
        parse_edited(json, &put_in(&1, ["tables", "wishes"], [])),
        "tables.wishes is not part of the format"
      )
    end

    test "a row with an extra key", %{json: json} do
      assert_malformed(
        parse_edited(
          json,
          &update_row(&1, "offers", 1, fn row -> Map.put(row, "colour", "red") end)
        ),
        "offers[1].colour is not part of the format"
      )
    end

    test "a row missing a key", %{json: json} do
      assert_malformed(
        parse_edited(json, &update_row(&1, "offers", 1, fn row -> Map.delete(row, "status") end)),
        "offers[1].status is missing"
      )
    end

    test ~s("12" for an integer), %{json: json} do
      assert_malformed(
        parse_edited(
          json,
          &update_row(&1, "events", 2, fn row -> Map.put(row, "sort_order", "12") end)
        ),
        "events[2].sort_order must be a whole number"
      )
    end

    test "an unknown enum value", %{json: json} do
      assert_malformed(
        parse_edited(
          json,
          &update_row(&1, "offers", 1, fn row -> Map.put(row, "status", "maybe") end)
        ),
        ~s(offers[1].status has an unknown value "maybe")
      )
    end

    test ~s("23/09/2026" for a date), %{json: json} do
      message =
        assert_malformed(
          parse_edited(
            json,
            &update_row(&1, "events", 0, fn row -> Map.put(row, "date", "23/09/2026") end)
          ),
          ~s(events[0].date must be a date written YYYY-MM-DD, not "23/09/2026")
        )

      assert message =~ "events[0].date"
    end

    test "a datetime with +02:00 and one with microseconds", %{json: json} do
      for value <- ["2026-09-25T14:05:00+02:00", "2026-09-25T12:05:00.123456Z"] do
        assert {:error, %Refusal{reason: :malformed, message: message}} =
                 parse_edited(
                   json,
                   &update_row(&1, "events", 0, fn row -> Map.put(row, "inserted_at", value) end)
                 )

        assert message =~ "This file is damaged: events[0].inserted_at must be a UTC time"
      end

      assert {:error, %Refusal{reason: :malformed, message: message}} =
               parse_edited(
                 json,
                 &put_in(&1, ["meta", "exported_at"], "2026-09-25T14:05:00+02:00")
               )

      assert message =~ "meta.exported_at must be a UTC time"
    end

    test ~s(money amounts "1,5" and "12abc", and currency "USD"), %{json: json} do
      for amount <- ["1,5", "12abc"] do
        assert_malformed(
          parse_edited(
            json,
            &update_row(&1, "settings", 0, fn row ->
              Map.put(row, "overall_budget", %{"amount" => amount, "currency" => "EUR"})
            end)
          ),
          ~s(settings[0].overall_budget has an amount that isn't a plain decimal number: "#{amount}")
        )
      end

      assert_malformed(
        parse_edited(
          json,
          &update_row(&1, "settings", 0, fn row ->
            Map.put(row, "overall_budget", %{"amount" => "45000", "currency" => "USD"})
          end)
        ),
        ~s(settings[0].overall_budget has the currency "USD"; only "EUR" is allowed)
      )
    end

    test "duplicate ids", %{json: json} do
      first_id = hd(json["tables"]["events"])["id"]

      assert_malformed(
        parse_edited(
          json,
          &update_row(&1, "events", 1, fn row -> Map.put(row, "id", first_id) end)
        ),
        "events[1].id repeats id #{first_id} (also events[0])"
      )
    end

    test "base64 garbage", %{json: json} do
      assert_malformed(
        parse_edited(
          json,
          &update_in(&1, ["files", Access.at(0), "data_base64"], fn _ -> "!!not base64!!" end)
        ),
        "files[0].data_base64 isn't valid base64"
      )
    end

    test "sha256 mismatch", %{json: json} do
      other = :crypto.hash(:sha256, "other") |> Base.encode16(case: :lower)

      assert_malformed(
        parse_edited(json, &put_in(&1, ["files", Access.at(0), "sha256"], other)),
        "files[0] doesn't match its checksum"
      )
    end

    test "byte_size mismatch", %{json: json} do
      assert_malformed(
        parse_edited(
          json,
          &update_in(&1, ["files", Access.at(0), "byte_size"], fn size -> size + 1 end)
        ),
        "files[0] doesn't match its byte size"
      )
    end

    test "a PNG declared as application/pdf", %{json: json} do
      assert_malformed(
        parse_edited(json, fn json ->
          update_in(json, ["files", Access.at(0)], fn entry ->
            file_entry(ReferenceFixtures.bytes(:png), "application/pdf", entry["file_key"])
          end)
        end),
        ~s(files[0] isn't the "application/pdf" file it claims to be)
      )
    end

    test ~s(a file key "../../../etc/passwd"), %{json: json} do
      assert_malformed(
        parse_edited(
          json,
          &put_in(&1, ["files", Access.at(0), "file_key"], "../../../etc/passwd")
        ),
        "files[0].file_key isn't a valid file key"
      )
    end

    test "a files entry no reference uses", %{json: json} do
      stray = file_entry(ReferenceFixtures.bytes(:png), "image/png", String.duplicate("A", 22))

      assert_malformed(
        parse_edited(json, &update_in(&1, ["files"], fn files -> files ++ [stray] end)),
        "files[1] isn't used by any file reference"
      )
    end

    test "a file reference with no files entry, accepted when its key is in missing_files",
         %{json: json, data: data} do
      key = data.references.file.file_key
      index = file_reference_index(json)

      assert_malformed(
        parse_edited(json, &Map.put(&1, "files", [])),
        ~s(references[#{index}].file_key refers to file "#{key}", which isn't in files or meta.missing_files)
      )

      assert {:ok, document} =
               parse_edited(json, fn json ->
                 json |> Map.put("files", []) |> put_in(["meta", "missing_files"], [key])
               end)

      assert document.files == %{}
      assert document.meta.missing_files == [key]
    end

    test "a files entry whose type differs from its reference's", %{json: json} do
      index = file_reference_index(json)

      assert_malformed(
        parse_edited(json, fn json ->
          update_in(json, ["files", Access.at(0)], fn entry ->
            file_entry(ReferenceFixtures.bytes(:png), "image/png", entry["file_key"])
          end)
        end),
        ~s(files[0].content_type is "image/png", but references[#{index}] says "application/pdf")
      )
    end

    test "a file over the 10 MiB upload limit (XC-21)", %{json: json} do
      pdf = ReferenceFixtures.bytes(:pdf)

      too_large =
        pdf <>
          :binary.copy(<<0>>, WeddingPlanner.References.Storage.max_bytes() + 1 - byte_size(pdf))

      assert_malformed(
        parse_edited(json, fn json ->
          update_in(json, ["files", Access.at(0)], fn entry ->
            file_entry(too_large, "application/pdf", entry["file_key"])
          end)
        end),
        "files[0] is larger than the 10485760-byte upload limit"
      )
    end

    test "missing_files: a bad key, or a key that is also in files", %{json: json, data: data} do
      assert_malformed(
        parse_edited(json, &put_in(&1, ["meta", "missing_files"], ["../x"])),
        "meta.missing_files[0] isn't a valid file key"
      )

      assert_malformed(
        parse_edited(
          json,
          &put_in(&1, ["meta", "missing_files"], [data.references.file.file_key])
        ),
        "meta.missing_files[0] names a file that is in files (files[0])"
      )
    end

    test "activity_entries.user_id not in users", %{json: json} do
      assert_malformed(
        parse_edited(
          json,
          &update_row(&1, "activity_entries", 0, fn row -> Map.put(row, "user_id", 999_999) end)
        ),
        "activity_entries[0].user_id refers to user 999999, who isn't in users"
      )
    end

    test "tasks.owner_id not in users", %{json: json, data: data} do
      index = Enum.find_index(json["tables"]["tasks"], &(&1["owner_id"] == data.lotte.id))

      assert_malformed(
        parse_edited(
          json,
          &update_in(&1, ["users"], fn users ->
            Enum.reject(users, fn u -> u["id"] == data.lotte.id end)
          end)
        ),
        "tasks[#{index}].owner_id refers to user #{data.lotte.id}, who isn't in users"
      )
    end

    test "structural damage is located too", %{json: json} do
      assert_malformed(parse_edited(json, &Map.delete(&1, "users")), "users is missing")

      assert_malformed(
        parse_edited(json, &Map.put(&1, "extra", true)),
        "extra is not part of the format"
      )

      assert_malformed(parse_edited(json, &Map.put(&1, "tables", [])), "tables must be an object")

      assert_malformed(
        parse_edited(json, &put_in(&1, ["tables", "events"], %{})),
        "tables.events must be a list"
      )

      assert_malformed(
        parse_edited(json, &put_in(&1, ["meta", "source_host"], "")),
        "meta.source_host must be non-empty text"
      )

      assert_malformed(
        parse_edited(json, &put_in(&1, ["meta", "schema_version"], "20260924124144")),
        "meta.schema_version must be a whole number"
      )

      assert_malformed(
        parse_edited(
          json,
          &update_in(&1, ["users", Access.at(0)], fn u -> Map.put(u, "passkeys", []) end)
        ),
        "users[0].passkeys is not part of the format"
      )
    end
  end
end
