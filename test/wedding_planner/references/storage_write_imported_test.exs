defmodule WeddingPlanner.References.StorageWriteImportedTest do
  @moduledoc """
  `Storage.write_imported/2` (`DR-94`, `DR-29`, `XC-21`): an imported file is written
  under its own key with the upload rules re-checked, `.part` plus rename, never over an
  existing file.
  """
  use ExUnit.Case, async: false

  alias WeddingPlanner.ReferenceFixtures
  alias WeddingPlanner.References.Storage

  @moduletag :tmp_dir

  @key "abcdefghijklmnopqrstuv"

  setup %{tmp_dir: tmp_dir} do
    previous = Application.fetch_env!(:wedding_planner, :uploads_dir)
    Application.put_env(:wedding_planner, :uploads_dir, Path.join(tmp_dir, "uploads"))
    on_exit(fn -> Application.put_env(:wedding_planner, :uploads_dir, previous) end)
    %{dir: Path.join(tmp_dir, "uploads")}
  end

  defp stored(content_type \\ "application/pdf"),
    do: %{file_key: @key, content_type: content_type}

  test "writes the bytes at path_for/1, leaving no .part", %{dir: dir} do
    pdf = ReferenceFixtures.bytes(:pdf)
    assert :ok = Storage.write_imported(stored(), pdf)
    assert File.read!(Storage.path_for(stored())) == pdf
    assert File.ls!(dir) == [@key <> ".pdf"]
  end

  test "never overwrites an existing file" do
    assert :ok = Storage.write_imported(stored(), ReferenceFixtures.bytes(:pdf))
    assert {:error, :exists} = Storage.write_imported(stored(), "%PDF-1.7 other")
    assert File.read!(Storage.path_for(stored())) == ReferenceFixtures.bytes(:pdf)
  end

  test "re-checks type, size and key", %{dir: dir} do
    assert {:error, :unsupported_type} =
             Storage.write_imported(stored(), ReferenceFixtures.bytes(:png))

    assert {:error, :unsupported_type} = Storage.write_imported(stored("text/html"), "<html>")
    assert {:error, :empty} = Storage.write_imported(stored(), "")

    assert {:error, :too_large} =
             Storage.write_imported(stored(), "%PDF-" <> :binary.copy("x", Storage.max_bytes()))

    assert {:error, :einval} =
             Storage.write_imported(
               %{file_key: "../../etc/passwd", content_type: "application/pdf"},
               "%PDF-"
             )

    refute File.exists?(dir) and File.ls!(dir) != []
  end
end
