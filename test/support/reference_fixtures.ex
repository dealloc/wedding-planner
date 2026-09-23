defmodule WeddingPlanner.ReferenceFixtures do
  @moduledoc """
  Test support for references (`XC-20`–`XC-24`, `DR-28`, `DR-29`): tiny upload files,
  valid and hostile, written to a per-test temp directory, the stand-in owner, and
  cleanup of anything a test leaves in `:uploads_dir`.

  ## The stand-in owner (`DR-28`)

  Offers (C2) and invoices (B2) do not exist yet, so `owner/0` is
  `%Owner{attrs: %{}, log_entity: {:owner_stub, 1}, name: "the test owner"}`. Its empty
  `attrs` match **every** row — fine inside one sandboxed test, never in production.

  ## Cleanup

  `track_uploads_dir/0` (call it from `setup`) records the files already in
  `:uploads_dir` and, on exit, removes every file that was not there before — so a test
  that fails half-way (or a fail-proof run with a broken implementation) still leaves the
  directory as it found it. `new_upload_files/1` is the same diff, used to assert that a
  refused upload left nothing behind. Reference test modules are `async: false`, so no
  other test writes to the directory while one runs.
  """

  import ExUnit.Callbacks, only: [on_exit: 1]

  alias WeddingPlanner.References.Owner
  alias WeddingPlanner.References.Storage

  @doc "The stand-in owner (see moduledoc)."
  @spec owner() :: Owner.t()
  def owner do
    %Owner{attrs: %{}, log_entity: {:owner_stub, 1}, name: "the test owner"}
  end

  @doc "The configured uploads directory, expanded."
  def uploads_dir, do: Path.expand(Application.fetch_env!(:wedding_planner, :uploads_dir))

  @doc "A fresh temp directory for upload source files, removed on exit."
  def tmp_upload_dir! do
    dir =
      Path.join(
        System.tmp_dir!(),
        "wp-ref-src-#{System.unique_integer([:positive])}-#{:rand.uniform(1_000_000)}"
      )

    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf!(dir) end)
    dir
  end

  @doc "Snapshots `:uploads_dir` and removes, on exit, every file added after this call."
  def track_uploads_dir do
    before = list_uploads()

    on_exit(fn ->
      for name <- list_uploads() -- before, do: File.rm(Path.join(uploads_dir(), name))
    end)

    before
  end

  @doc "Files in `:uploads_dir` that were not in `before` (a `track_uploads_dir/0` result)."
  def new_upload_files(before), do: list_uploads() -- before

  defp list_uploads do
    case File.ls(uploads_dir()) do
      {:ok, names} -> names
      {:error, :enoent} -> []
    end
  end

  @doc """
  Writes a fixture file of `kind` named `name` into `dir`; returns `{path, name}` — the
  shape `WeddingPlanner.References.create_file_reference/4` takes.

  Kinds: `:pdf`, `:png`, `:jpeg`, `:webp` (tiny but correctly-magicked); `:html` (an
  HTML page — name it `x.pdf` to lie about its type); `:heic` (an ISO-BMFF `ftypheic`
  header, out of scope per `DR-12`); `:empty`; `:too_large` (a PNG header in a sparse
  file of `max_bytes() + 1` bytes, so only the size is wrong); `:max_size` (the same at
  exactly `max_bytes()` bytes).
  """
  def write_fixture!(dir, kind, name) do
    path = Path.join(dir, "#{System.unique_integer([:positive])}-#{kind}")

    case kind do
      :too_large -> write_sparse!(path, Storage.max_bytes() + 1)
      :max_size -> write_sparse!(path, Storage.max_bytes())
      _ -> File.write!(path, bytes(kind))
    end

    {path, name}
  end

  @doc "The raw bytes of a small fixture of `kind`."
  def bytes(:pdf), do: "%PDF-1.4\n1 0 obj << /Type /Catalog >> endobj\ntrailer << >>\n%%EOF\n"

  def bytes(:png),
    do: <<0x89, "PNG", 0x0D, 0x0A, 0x1A, 0x0A, 0, 0, 0, 13, "IHDR", 0, 0, 0, 1, 0, 0, 0, 1>>

  def bytes(:jpeg), do: <<0xFF, 0xD8, 0xFF, 0xE0, 0, 16, "JFIF", 0, 1, 1, 0, 0xFF, 0xD9>>
  def bytes(:webp), do: <<"RIFF", 26::little-32, "WEBP", "VP8 ", 14::little-32, 0::112>>
  def bytes(:html), do: "<!DOCTYPE html><html><body><script>alert(1)</script></body></html>"
  def bytes(:heic), do: <<0, 0, 0, 24, "ftypheic", 0, 0, 0, 0, "mif1heic">>
  def bytes(:empty), do: ""

  # A PNG header, then one byte at offset `size - 1`: a file of exactly `size` bytes
  # that costs almost nothing to create (the gap is a hole on file systems that support
  # it). The header makes it a *valid type*, so only its size can be what refuses it.
  defp write_sparse!(path, size) do
    {:ok, fd} = :file.open(path, [:write, :raw, :binary])
    :ok = :file.write(fd, bytes(:png))
    :ok = :file.pwrite(fd, size - 1, <<0>>)
    :ok = :file.close(fd)
  end
end
