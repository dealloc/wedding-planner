defmodule WeddingPlanner.References.StorageTest do
  @moduledoc """
  `docs/04-cross-cutting.md` `XC-21`, `XC-23`; `DR-29`, `DR-30` — local file storage for
  references: type decided by magic bytes, the 10 MiB limit, random flat naming, path
  validation, atomic writes and deletion.

  `async: false`: some tests repoint `:uploads_dir` at an unwritable location, and the
  "nothing left behind" assertions diff the uploads directory, so nothing else may write
  there meanwhile. Every file a test creates is removed on exit
  (`ReferenceFixtures.track_uploads_dir/0`).
  """
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog
  import WeddingPlanner.ReferenceFixtures

  alias WeddingPlanner.References.Storage

  setup do
    before = track_uploads_dir()
    %{before: before, src: tmp_upload_dir!()}
  end

  describe "max_bytes/0 and allowed_types/0 (XC-21, DR-29)" do
    test "the limit is 10 MiB" do
      assert Storage.max_bytes() == 10_485_760
    end

    test "exactly the four types are allowed" do
      assert Enum.map(Storage.allowed_types(), & &1.content_type) ==
               ["application/pdf", "image/png", "image/jpeg", "image/webp"]
    end
  end

  describe "sniff/1 (DR-29)" do
    test "recognises each allowed type by its magic bytes" do
      assert Storage.sniff(bytes(:pdf)) == {:ok, "application/pdf", "pdf"}
      assert Storage.sniff(bytes(:png)) == {:ok, "image/png", "png"}
      assert Storage.sniff(bytes(:jpeg)) == {:ok, "image/jpeg", "jpg"}
      assert Storage.sniff(bytes(:webp)) == {:ok, "image/webp", "webp"}
    end

    test "refuses HTML, HEIC, other RIFF formats, truncated magic and empty input" do
      assert Storage.sniff(bytes(:html)) == :error
      assert Storage.sniff(bytes(:heic)) == :error
      assert Storage.sniff(<<"RIFF", 0::32, "WAVE">>) == :error
      assert Storage.sniff(<<0x89, "PNG">>) == :error
      assert Storage.sniff("%PDF") == :error
      assert Storage.sniff("") == :error
    end
  end

  describe "store/2 accepts the allowed types (XC-21, DR-29)" do
    for {kind, content_type, ext} <- [
          {:pdf, "application/pdf", "pdf"},
          {:png, "image/png", "png"},
          {:jpeg, "image/jpeg", "jpg"},
          {:webp, "image/webp", "webp"}
        ] do
      test "stores a #{kind} with its sniffed type, byte for byte", %{src: src} do
        {path, name} = write_fixture!(src, unquote(kind), "upload.#{unquote(ext)}")

        assert {:ok, stored} = Storage.store(path, name)
        assert stored.content_type == unquote(content_type)
        assert stored.file_name == name
        assert stored.byte_size == byte_size(bytes(unquote(kind)))
        assert Regex.match?(~r/\A[A-Za-z0-9_-]{22}\z/, stored.file_key)

        stored_path = Storage.path_for(stored)
        assert Path.basename(stored_path) == stored.file_key <> "." <> unquote(ext)
        assert File.read!(stored_path) == bytes(unquote(kind))
        assert Storage.exists?(stored)
      end
    end

    test "a PNG uploaded as photo.jpg is stored as image/png with .png", %{src: src} do
      {path, name} = write_fixture!(src, :png, "photo.jpg")

      assert {:ok, stored} = Storage.store(path, name)
      assert stored.content_type == "image/png"
      assert Path.extname(Storage.path_for(stored)) == ".png"
      assert stored.file_name == "photo.jpg"
    end

    test "a file of exactly max_bytes() is accepted", %{src: src} do
      {path, name} = write_fixture!(src, :max_size, "big.png")

      assert {:ok, stored} = Storage.store(path, name)
      assert stored.byte_size == Storage.max_bytes()
    end

    test "every upload gets its own random key", %{src: src} do
      {path, name} = write_fixture!(src, :pdf, "a.pdf")

      assert {:ok, a} = Storage.store(path, name)
      assert {:ok, b} = Storage.store(path, name)
      assert a.file_key != b.file_key
    end
  end

  describe "store/2 refuses (XC-21, DR-29)" do
    test "an HTML page renamed .pdf — nothing left in the uploads dir", %{src: src, before: b} do
      {path, name} = write_fixture!(src, :html, "x.pdf")

      assert Storage.store(path, name) == {:error, :unsupported_type}
      assert new_upload_files(b) == []
    end

    test "a HEIC / unknown blob", %{src: src, before: b} do
      {path, name} = write_fixture!(src, :heic, "IMG_0001.heic")

      assert Storage.store(path, name) == {:error, :unsupported_type}
      assert new_upload_files(b) == []
    end

    test "an empty file", %{src: src, before: b} do
      {path, name} = write_fixture!(src, :empty, "empty.pdf")

      assert Storage.store(path, name) == {:error, :empty}
      assert new_upload_files(b) == []
    end

    test "max_bytes() + 1 bytes, even with valid magic", %{src: src, before: b} do
      {path, name} = write_fixture!(src, :too_large, "huge.png")
      assert File.stat!(path).size == Storage.max_bytes() + 1

      assert Storage.store(path, name) == {:error, :too_large}
      assert new_upload_files(b) == []
    end

    test "a temp path that does not exist", %{src: src, before: b} do
      assert Storage.store(Path.join(src, "nope"), "nope.pdf") == {:error, :enoent}
      assert new_upload_files(b) == []
    end

    test "a directory instead of a file", %{src: src, before: b} do
      assert Storage.store(src, "dir.pdf") == {:error, :eisdir}
      assert new_upload_files(b) == []
    end
  end

  describe "store/2 when the write fails (DR-29)" do
    setup do
      original = Application.fetch_env!(:wedding_planner, :uploads_dir)
      on_exit(fn -> Application.put_env(:wedding_planner, :uploads_dir, original) end)
      :ok
    end

    test "uploads dir cannot be created → posix error, nothing written", %{src: src} do
      blocker = Path.join(src, "a-regular-file")
      File.write!(blocker, "x")
      Application.put_env(:wedding_planner, :uploads_dir, Path.join(blocker, "uploads"))

      {path, name} = write_fixture!(src, :pdf, "a.pdf")
      assert Storage.store(path, name) == {:error, :enotdir}
    end

    test "uploads dir not writable → posix error, no .part left", %{src: src} do
      readonly = Path.join(src, "readonly")
      File.mkdir_p!(readonly)
      File.chmod!(readonly, 0o500)
      on_exit(fn -> File.chmod(readonly, 0o700) end)
      Application.put_env(:wedding_planner, :uploads_dir, readonly)

      {path, name} = write_fixture!(src, :pdf, "a.pdf")
      assert Storage.store(path, name) == {:error, :eacces}
      assert File.ls!(readonly) == []
    end
  end

  describe "paths never leave the uploads dir (DR-29)" do
    test "the stored file is inside :uploads_dir and named by its key, not the upload's name",
         %{src: src} do
      {path, _} = write_fixture!(src, :png, "ignored")
      evil_name = "../../escape.png"
      # If the implementation ever builds the path from the name (the fail-proof), this
      # is where the file would land — remove it so the run leaves nothing behind.
      on_exit(fn -> File.rm(Path.expand(evil_name, uploads_dir())) end)

      assert {:ok, stored} = Storage.store(path, evil_name)

      stored_path = Path.expand(Storage.path_for(stored))
      assert String.starts_with?(stored_path, uploads_dir() <> "/")
      assert Path.dirname(stored_path) == uploads_dir()
      assert Path.basename(stored_path) == stored.file_key <> ".png"
      assert File.regular?(stored_path)
      refute File.exists?(Path.expand(evil_name, uploads_dir()))

      # The original name is kept, sanitised, for the download name only.
      assert stored.file_name == "escape.png"
    end

    test "path_for/1 refuses a traversal key" do
      assert_raise ArgumentError, fn ->
        Storage.path_for(%{file_key: "../../etc/passwd", content_type: "application/pdf"})
      end
    end

    test "path_for/1 refuses a wrong-length key, a key with a separator, and nil" do
      for key <- [
            "abc",
            String.duplicate("a", 23),
            "aaaaaaaaaa/aaaaaaaaaaa",
            "aaaaaaaaaa.aaaaaaaaaaa",
            nil
          ] do
        assert_raise ArgumentError, fn ->
          Storage.path_for(%{file_key: key, content_type: "image/png"})
        end
      end
    end

    test "path_for/1 refuses a type outside the four" do
      key = String.duplicate("a", 22)

      for type <- ["text/html", "image/heic", "../png", nil] do
        assert_raise ArgumentError, fn ->
          Storage.path_for(%{file_key: key, content_type: type})
        end
      end
    end

    test "path_for/1 builds <dir>/<key>.<ext> for a valid key" do
      key = String.duplicate("A_-z", 5) <> "09"

      assert Storage.path_for(%{file_key: key, content_type: "image/webp"}) ==
               Path.join(Application.fetch_env!(:wedding_planner, :uploads_dir), key <> ".webp")
    end
  end

  describe "sanitize_file_name/2 (DR-29 — stored for the download name, never a path)" do
    test "keeps only the last path segment, for / and \\" do
      assert Storage.sanitize_file_name("../../etc/passwd", "pdf") == "passwd"
      assert Storage.sanitize_file_name("C:\\Users\\me\\quote.pdf", "pdf") == "quote.pdf"
    end

    test "strips control characters and trims" do
      assert Storage.sanitize_file_name("  quo\nte\u0000.pdf\r ", "pdf") == "quote.pdf"
    end

    test "caps the length at 200, keeping the extension" do
      name = String.duplicate("é", 300) <> ".pdf"
      sanitized = Storage.sanitize_file_name(name, "pdf")

      assert String.length(sanitized) == 200
      assert String.ends_with?(sanitized, ".pdf")
    end

    test "falls back to file.<ext> when nothing usable is left" do
      assert Storage.sanitize_file_name("", "pdf") == "file.pdf"
      assert Storage.sanitize_file_name("..", "png") == "file.png"
      assert Storage.sanitize_file_name("dir/", "jpg") == "file.jpg"
    end
  end

  describe "delete/1 and delete_files/1 (DR-30)" do
    test "removes the stored file", %{src: src} do
      {path, name} = write_fixture!(src, :pdf, "a.pdf")
      {:ok, stored} = Storage.store(path, name)

      assert Storage.delete(stored) == :ok
      refute Storage.exists?(stored)
    end

    test "a file that is already missing is :ok, with a warning", %{src: src} do
      {path, name} = write_fixture!(src, :pdf, "a.pdf")
      {:ok, stored} = Storage.store(path, name)
      File.rm!(Storage.path_for(stored))

      log = capture_log(fn -> assert Storage.delete(stored) == :ok end)
      assert log =~ "already missing"
    end

    test "a reference without a file (URL kind) is a no-op" do
      assert Storage.delete(%{file_key: nil, content_type: nil}) == :ok
    end

    test "delete_files/1 removes each", %{src: src} do
      stored =
        for kind <- [:pdf, :png] do
          {path, name} = write_fixture!(src, kind, "f")
          {:ok, stored} = Storage.store(path, name)
          stored
        end

      assert Storage.delete_files(stored) == :ok
      refute Enum.any?(stored, &Storage.exists?/1)
    end
  end
end
