defmodule WeddingPlanner.ReferencesTest do
  @moduledoc """
  `docs/04-cross-cutting.md` `XC-20` through `XC-24`, `XC-01`, `XC-10`–`XC-12`; `DR-28`,
  `DR-29`, `DR-30` — the owner-agnostic references context (slice B1's data layer).

  **A real owner (`DR-28`):** these tests use `ReferenceFixtures.owner/0`, a freshly
  inserted offer's `WeddingPlanner.Offers.reference_owner/1` (vendor name "the test
  owner"), so every reference belongs to offer "the test owner" and satisfies B2's
  `references_exactly_one_owner` CHECK. Activity entries are therefore asserted with
  `entity_type: "offer"`, and log sentences read "... offer 'the test owner'" rather
  than the bare owner name.

  `async: false` because the "nothing left behind" assertions diff `:uploads_dir`; every
  file a test creates is removed on exit (`ReferenceFixtures.track_uploads_dir/0`).
  """
  use WeddingPlanner.DataCase, async: false

  import ExUnit.CaptureLog
  import WeddingPlanner.ReferenceFixtures

  alias WeddingPlanner.Accounts.Scope
  alias WeddingPlanner.Accounts.User
  alias WeddingPlanner.Log
  alias WeddingPlanner.Log.Entry
  alias WeddingPlanner.Realtime
  alias WeddingPlanner.References
  alias WeddingPlanner.References.Owner
  alias WeddingPlanner.References.Reference
  alias WeddingPlanner.References.Storage

  setup do
    user = %User{} |> User.changeset(%{display_name: "Wannes"}) |> Repo.insert!()

    %{
      scope: Scope.for_user(user),
      owner: owner(),
      before: track_uploads_dir(),
      src: tmp_upload_dir!()
    }
  end

  defp upload!(ctx, kind, name, attrs \\ %{}) do
    {:ok, reference} =
      References.create_file_reference(
        ctx.scope,
        ctx.owner,
        attrs,
        write_fixture!(ctx.src, kind, name)
      )

    reference
  end

  defp link!(ctx, label, url \\ "https://example.com/x") do
    {:ok, reference} =
      References.create_url_reference(ctx.scope, ctx.owner, %{"label" => label, "url" => url})

    reference
  end

  defp reference_count, do: Repo.aggregate(Reference, :count)
  defp entries, do: Repo.all(from e in Entry, order_by: e.id)

  describe "create_file_reference/4 accepts the allowed types (XC-20, XC-21, DR-29)" do
    for {kind, content_type} <- [
          pdf: "application/pdf",
          png: "image/png",
          jpeg: "image/jpeg",
          webp: "image/webp"
        ] do
      test "stores a #{kind} with its sniffed content type", ctx do
        reference = upload!(ctx, unquote(kind), "upload", %{"label" => "Quote"})

        assert reference.kind == :file
        assert reference.content_type == unquote(content_type)
        assert reference.file_name == "upload"
        assert reference.byte_size == byte_size(bytes(unquote(kind)))
        assert is_nil(reference.url)
        assert Storage.exists?(reference)
        assert Repo.get!(Reference, reference.id).file_key == reference.file_key
      end
    end

    test "a PNG uploaded as photo.jpg is stored as image/png, .png", ctx do
      reference = upload!(ctx, :png, "photo.jpg")

      assert reference.content_type == "image/png"
      assert Path.extname(Storage.path_for(reference)) == ".png"
    end

    test "the stored file is inside :uploads_dir", ctx do
      evil_name = "../../ctx-escape.pdf"
      on_exit(fn -> File.rm(Path.expand(evil_name, uploads_dir())) end)
      reference = upload!(ctx, :pdf, evil_name)
      path = Path.expand(Storage.path_for(reference))

      assert String.starts_with?(path, uploads_dir() <> "/")
      assert Path.dirname(path) == uploads_dir()
      refute File.exists?(Path.expand(evil_name, uploads_dir()))
      assert reference.file_name == "ctx-escape.pdf"
    end

    test "a blank or missing label defaults to the original filename (DR-29)", ctx do
      assert upload!(ctx, :pdf, "Offerte zaal.pdf", %{"label" => "   "}).label ==
               "Offerte zaal.pdf"

      assert upload!(ctx, :pdf, "Offerte 2.pdf").label == "Offerte 2.pdf"
    end

    test "a given label is trimmed", ctx do
      assert upload!(ctx, :pdf, "a.pdf", %{"label" => "  Quote  "}).label == "Quote"
    end

    test "file fields cannot be cast from attrs", ctx do
      reference =
        upload!(ctx, :pdf, "a.pdf", %{
          "label" => "Quote",
          "file_key" => "../../etc/passwd",
          "content_type" => "text/html",
          "byte_size" => "1",
          "url" => "https://evil.example"
        })

      assert reference.content_type == "application/pdf"
      assert Regex.match?(~r/\A[A-Za-z0-9_-]{22}\z/, reference.file_key)
      assert is_nil(reference.url)
    end
  end

  describe "create_file_reference/4 refuses (XC-21, DR-29)" do
    for {kind, name, error} <- [
          {:html, "x.pdf", :unsupported_type},
          {:heic, "IMG_0001.heic", :unsupported_type},
          {:empty, "empty.pdf", :empty},
          {:too_large, "huge.png", :too_large}
        ] do
      test "#{kind} as #{name} → #{error}: no row, no file, no log entry", ctx do
        upload = write_fixture!(ctx.src, unquote(kind), unquote(name))

        assert References.create_file_reference(ctx.scope, ctx.owner, %{}, upload) ==
                 {:error, unquote(error)}

        assert reference_count() == 0
        assert new_upload_files(ctx.before) == []
        assert entries() == []
      end
    end

    test "an insert failure after the file was stored leaves no file behind", ctx do
      upload = write_fixture!(ctx.src, :pdf, "a.pdf")
      too_long = String.duplicate("x", Reference.label_max() + 1)

      assert {:error, changeset} =
               References.create_file_reference(
                 ctx.scope,
                 ctx.owner,
                 %{"label" => too_long},
                 upload
               )

      assert errors_on(changeset).label != []
      assert reference_count() == 0
      assert new_upload_files(ctx.before) == []
      assert entries() == []
    end

    test "an insert that raises after the file was stored leaves no file behind", ctx do
      # An owner FK the schema does not know (an owner type forgot its `belongs_to`) must
      # raise, not silently create an ownerless row (DR-28) — and the stored file goes
      # too. `offer_id` was this test's stand-in before C2 added it as a real field
      # (`WeddingPlanner.References.Reference`'s `belongs_to :offer`); a name no schema
      # will ever define is used here instead, to keep exercising the same invariant.
      bad_owner = %Owner{
        attrs: %{nonexistent_owner_id: 1},
        log_entity: {:owner_stub, 1},
        name: "x"
      }

      upload = write_fixture!(ctx.src, :pdf, "a.pdf")

      assert_raise KeyError, fn ->
        References.create_file_reference(ctx.scope, bad_owner, %{}, upload)
      end

      assert reference_count() == 0
      assert new_upload_files(ctx.before) == []
    end
  end

  describe "create_url_reference/3 (XC-20, DR-29)" do
    test "accepts an https URL", ctx do
      reference = link!(ctx, "Venue website", "https://example.com/x")

      assert reference.kind == :url
      assert reference.url == "https://example.com/x"
      assert is_nil(reference.file_key)
    end

    test "accepts http and trims", ctx do
      assert link!(ctx, " Site ", "  http://example.com  ").url == "http://example.com"
    end

    for url <- [
          "javascript:alert(1)",
          "ftp://example.com/file",
          "example.com",
          "data:text/plain;base64,SGVsbG8=",
          "file:///etc/passwd",
          "https://",
          "http:///path",
          "https://exa mple.com",
          ""
        ] do
      test "refuses #{inspect(url)}", ctx do
        assert {:error, changeset} =
                 References.create_url_reference(ctx.scope, ctx.owner, %{
                   "label" => "Link",
                   "url" => unquote(url)
                 })

        assert errors_on(changeset).url != []
        assert reference_count() == 0
      end
    end

    test "refuses a URL over 2000 characters", ctx do
      url = "https://example.com/" <> String.duplicate("a", 2000)

      assert {:error, changeset} =
               References.create_url_reference(ctx.scope, ctx.owner, %{
                 "label" => "L",
                 "url" => url
               })

      assert errors_on(changeset).url != []
    end

    test "requires a label", ctx do
      assert {:error, changeset} =
               References.create_url_reference(ctx.scope, ctx.owner, %{
                 "label" => "  ",
                 "url" => "https://example.com"
               })

      assert "can't be blank" in errors_on(changeset).label
    end
  end

  describe "database CHECKs (XC-20)" do
    # Every raw row below carries `ctx.owner`'s `offer_id` so only the CHECK each test
    # names is under test — `references_exactly_one_owner` (`DR-28`) is covered on its
    # own in `WeddingPlanner.InvoicesTest` (both owners, and neither, refused).
    test "a url row carrying a file_key is refused", ctx do
      assert_raise Ecto.ConstraintError, fn ->
        Repo.insert!(%Reference{
          kind: :url,
          label: "L",
          url: "https://example.com",
          file_key: String.duplicate("a", 22),
          offer_id: ctx.owner.attrs.offer_id
        })
      end
    end

    test "a file row without a file_key is refused", ctx do
      assert_raise Ecto.ConstraintError, fn ->
        Repo.insert!(%Reference{
          kind: :file,
          label: "L",
          file_name: "a.pdf",
          content_type: "application/pdf",
          byte_size: 10,
          offer_id: ctx.owner.attrs.offer_id
        })
      end
    end

    test "a url row without a url is refused", ctx do
      assert_raise Ecto.ConstraintError, fn ->
        Repo.insert!(%Reference{kind: :url, label: "L", offer_id: ctx.owner.attrs.offer_id})
      end
    end

    test "a file row with a disallowed type or size is refused", ctx do
      base = %Reference{
        kind: :file,
        label: "L",
        file_key: String.duplicate("a", 22),
        file_name: "a",
        content_type: "application/pdf",
        byte_size: 10,
        offer_id: ctx.owner.attrs.offer_id
      }

      assert_raise Ecto.ConstraintError, fn ->
        Repo.insert!(%{base | content_type: "text/html"})
      end

      assert_raise Ecto.ConstraintError, fn -> Repo.insert!(%{base | byte_size: 10_485_761}) end
      assert_raise Ecto.ConstraintError, fn -> Repo.insert!(%{base | byte_size: 0}) end
      assert Repo.insert!(base).id
    end

    test "two rows cannot share a file_key", ctx do
      row = %Reference{
        kind: :file,
        label: "L",
        file_key: String.duplicate("b", 22),
        file_name: "a",
        content_type: "application/pdf",
        byte_size: 10,
        offer_id: ctx.owner.attrs.offer_id
      }

      Repo.insert!(row)
      assert_raise Ecto.ConstraintError, fn -> Repo.insert!(row) end
    end
  end

  describe "list_references/1 and get_reference!/1" do
    test "lists the owner's references oldest first", ctx do
      a = upload!(ctx, :pdf, "a.pdf")
      b = link!(ctx, "b")
      c = upload!(ctx, :png, "c.png")

      assert Enum.map(References.list_references(ctx.owner), & &1.id) == [a.id, b.id, c.id]
      assert References.get_reference!(b.id).label == "b"
    end
  end

  describe "update_reference/4 (XC-10, XC-01)" do
    test "renames a file reference, one entry on the owner", ctx do
      reference = upload!(ctx, :pdf, "a.pdf", %{"label" => "Quote"})
      Repo.delete_all(Entry)

      assert {:ok, updated} =
               References.update_reference(ctx.scope, ctx.owner, reference, %{
                 "label" => "Final quote"
               })

      assert updated.label == "Final quote"

      {:offer, owner_id} = ctx.owner.log_entity

      assert [entry] = entries()
      assert entry.entity_type == "offer"
      assert entry.entity_id == owner_id

      assert entry.description ==
               "Wannes renamed reference 'Quote' on offer 'the test owner' to 'Final quote'"
    end

    test "a file reference's file fields and url cannot be changed", ctx do
      reference = upload!(ctx, :pdf, "a.pdf")

      {:ok, updated} =
        References.update_reference(ctx.scope, ctx.owner, reference, %{
          "file_key" => String.duplicate("z", 22),
          "url" => "https://example.com"
        })

      assert updated.file_key == reference.file_key
      assert is_nil(updated.url)
    end

    test "changes a link's URL and label: one entry per field", ctx do
      reference = link!(ctx, "Site", "https://a.example")
      Repo.delete_all(Entry)

      {:ok, _} =
        References.update_reference(ctx.scope, ctx.owner, reference, %{
          "label" => "Venue site",
          "url" => "https://b.example"
        })

      assert Enum.map(entries(), & &1.description) == [
               "Wannes renamed reference 'Site' on offer 'the test owner' to 'Venue site'",
               "Wannes changed the URL of reference 'Site' on offer 'the test owner': https://a.example → https://b.example"
             ]
    end

    test "a link's URL is re-validated", ctx do
      reference = link!(ctx, "Site")

      assert {:error, changeset} =
               References.update_reference(ctx.scope, ctx.owner, reference, %{
                 "url" => "javascript:alert(1)"
               })

      assert errors_on(changeset).url != []
    end

    test "a blank label is refused on rename", ctx do
      reference = upload!(ctx, :pdf, "a.pdf")

      assert {:error, changeset} =
               References.update_reference(ctx.scope, ctx.owner, reference, %{"label" => ""})

      assert "can't be blank" in errors_on(changeset).label
    end

    test "no change, no entry", ctx do
      reference = link!(ctx, "Site")
      Repo.delete_all(Entry)

      {:ok, _} =
        References.update_reference(ctx.scope, ctx.owner, reference, %{"label" => "Site"})

      assert entries() == []
    end

    test "refuses a reference that belongs to another owner", ctx do
      reference = link!(ctx, "Site")
      Repo.delete_all(Entry)
      other = %Owner{attrs: %{id: -1}, log_entity: {:owner_stub, 2}, name: "another owner"}

      assert References.update_reference(ctx.scope, other, reference, %{"label" => "X"}) ==
               {:error, :not_owned}

      assert Repo.get!(Reference, reference.id).label == "Site"
      assert entries() == []
    end
  end

  describe "delete_reference/3 (DR-30, XC-10)" do
    test "deletes the row and the file, one entry on the owner", ctx do
      reference = upload!(ctx, :pdf, "a.pdf", %{"label" => "Quote"})
      Repo.delete_all(Entry)

      assert {:ok, _} = References.delete_reference(ctx.scope, ctx.owner, reference)

      assert is_nil(Repo.get(Reference, reference.id))
      refute Storage.exists?(reference)
      assert [entry] = entries()
      assert entry.entity_type == "offer"
      assert entry.description == "Wannes removed reference 'Quote' from offer 'the test owner'"
    end

    test "a file already removed from disk is not an error", ctx do
      reference = upload!(ctx, :pdf, "a.pdf")
      File.rm!(Storage.path_for(reference))

      capture_log(fn ->
        assert {:ok, _} = References.delete_reference(ctx.scope, ctx.owner, reference)
      end)

      assert is_nil(Repo.get(Reference, reference.id))
    end

    test "deletes a link", ctx do
      reference = link!(ctx, "Site")
      assert {:ok, _} = References.delete_reference(ctx.scope, ctx.owner, reference)
      assert reference_count() == 0
    end

    test "refuses a reference that belongs to another owner: row and file untouched", ctx do
      reference = upload!(ctx, :pdf, "a.pdf")
      other = %Owner{attrs: %{id: -1}, log_entity: {:owner_stub, 2}, name: "another owner"}

      assert References.delete_reference(ctx.scope, other, reference) == {:error, :not_owned}
      assert Repo.get(Reference, reference.id)
      assert Storage.exists?(reference)
    end
  end

  describe "logging on create (XC-10)" do
    test "a file upload writes one entry on the owner, naming the type", ctx do
      upload!(ctx, :pdf, "a.pdf", %{"label" => "Quote"})

      {:offer, owner_id} = ctx.owner.log_entity

      assert [entry] = entries()
      assert entry.entity_type == "offer"
      assert entry.entity_id == owner_id
      assert entry.description == "Wannes attached 'Quote' (PDF) to offer 'the test owner'"
    end

    test "a link writes one entry on the owner", ctx do
      link!(ctx, "Venue website")

      assert [entry] = entries()
      assert entry.entity_type == "offer"
      assert entry.description == "Wannes added link 'Venue website' to offer 'the test owner'"
    end
  end

  describe "delete_owner_references/2 + purge_deleted/1 (XC-24, XC-12, DR-30)" do
    test "inside Log.action: one child per reference, no files removed until purge", ctx do
      a = upload!(ctx, :pdf, "a.pdf", %{"label" => "Quote"})
      b = upload!(ctx, :png, "b.png", %{"label" => "Plan"})
      c = link!(ctx, "Site")
      Repo.delete_all(Entry)
      Realtime.subscribe(:reference)

      {:ok, deleted} =
        Log.action(ctx.scope, "Wannes deleted the test owner", fn ->
          deleted = References.delete_owner_references(ctx.scope, ctx.owner)

          # Still inside the owner's transaction: rows gone, files untouched.
          assert Storage.exists?(a) and Storage.exists?(b)
          deleted
        end)

      assert Enum.map(deleted, & &1.id) == [a.id, b.id, c.id]
      assert reference_count() == 0

      # Committed, but not yet purged: files still there, nothing broadcast.
      assert Storage.exists?(a) and Storage.exists?(b)
      refute_received {Realtime, :reference, _}

      [summary | children] = entries()
      assert is_nil(summary.entity_type)
      assert Enum.all?(children, &(&1.parent_id == summary.id))
      assert Enum.all?(children, &(&1.entity_type == "offer"))

      assert Enum.map(children, & &1.description) == [
               "Wannes removed reference 'Quote' (offer 'the test owner' deleted)",
               "Wannes removed reference 'Plan' (offer 'the test owner' deleted)",
               "Wannes removed reference 'Site' (offer 'the test owner' deleted)"
             ]

      assert References.purge_deleted(deleted) == :ok

      refute Storage.exists?(a)
      refute Storage.exists?(b)

      for id <- [a.id, b.id, c.id] do
        assert_received {Realtime, :reference, {:deleted, ^id}}
      end
    end

    test "a rolled-back owner deletion keeps every row and every file", ctx do
      a = upload!(ctx, :pdf, "a.pdf")

      assert_raise RuntimeError, fn ->
        Log.action(ctx.scope, "Wannes deleted the test owner", fn ->
          References.delete_owner_references(ctx.scope, ctx.owner)
          raise "owner delete failed"
        end)
      end

      assert Repo.get(Reference, a.id)
      assert Storage.exists?(a)
    end

    test "purge tolerates files that are already gone", ctx do
      a = upload!(ctx, :pdf, "a.pdf")

      {:ok, deleted} =
        Log.action(ctx.scope, "s", fn ->
          References.delete_owner_references(ctx.scope, ctx.owner)
        end)

      File.rm!(Storage.path_for(a))

      capture_log(fn -> assert References.purge_deleted(deleted) == :ok end)
    end
  end

  describe "reference_deletion_effects/1 (XC-24, XC-40)" do
    test "[] when the owner has none", ctx do
      assert References.reference_deletion_effects(ctx.owner) == []
    end

    test "counts files and links", ctx do
      upload!(ctx, :pdf, "a.pdf")
      upload!(ctx, :png, "b.png")
      link!(ctx, "Site")

      assert References.reference_deletion_effects(ctx.owner) == [
               %{label: "3 references are deleted (2 files, 1 link)", count: 3}
             ]
    end

    test "singular, one kind only", ctx do
      upload!(ctx, :pdf, "a.pdf")

      assert References.reference_deletion_effects(ctx.owner) == [
               %{label: "1 reference is deleted (1 file)", count: 1}
             ]
    end
  end

  describe "broadcasts on :reference (XC-01)" do
    setup do
      Realtime.subscribe(:reference)
      :ok
    end

    test "create file, create link, update, delete", ctx do
      file = upload!(ctx, :pdf, "a.pdf")
      file_id = file.id
      assert_received {Realtime, :reference, {:created, %Reference{id: ^file_id}}}

      link = link!(ctx, "Site")
      link_id = link.id
      assert_received {Realtime, :reference, {:created, %Reference{id: ^link_id}}}

      {:ok, _} = References.update_reference(ctx.scope, ctx.owner, link, %{"label" => "New"})
      assert_received {Realtime, :reference, {:updated, %Reference{id: ^link_id, label: "New"}}}

      {:ok, _} = References.delete_reference(ctx.scope, ctx.owner, file)
      assert_received {Realtime, :reference, {:deleted, ^file_id}}
    end

    test "a refused upload broadcasts nothing", ctx do
      upload = write_fixture!(ctx.src, :html, "x.pdf")

      {:error, :unsupported_type} =
        References.create_file_reference(ctx.scope, ctx.owner, %{}, upload)

      refute_received {Realtime, :reference, _}
    end
  end
end
