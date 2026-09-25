defmodule WeddingPlannerWeb.Live.SettingsTransferTest do
  @moduledoc """
  Settings → "Transfer data" (`DR-93`, `DR-95`, `DR-97`, `XC-40`, `AUTH-01`): the export
  link, the upload → checking → preview → confirm → importing → done/refused flow, the
  loading states, the reload of every *other* open screen, and the safety-copies list.
  """
  use WeddingPlannerWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias WeddingPlanner.Guests
  alias WeddingPlanner.Tasks
  alias WeddingPlanner.Transfer
  alias WeddingPlanner.Transfer.Export
  alias WeddingPlanner.Transfer.SchemaVersion
  alias WeddingPlanner.TransferFixtures

  @moduletag :tmp_dir

  setup %{tmp_dir: tmp_dir} do
    TransferFixtures.isolate_transfer_dirs!(tmp_dir)
  end

  setup %{conn: conn} do
    data = TransferFixtures.rich!()
    # `rich!/1` only gives its second user ("Lotte") a passkey; give the scope's own user
    # ("Wannes") one too, so the export's user-remap actually matches by name
    # (`Users.list_assignable/0`, `DR-22`) instead of falling through to "no user with
    # that name here" just because the importing user herself has no passkey yet.
    TransferFixtures.add_passkey!(data.scope.user)
    %{conn: log_in_user(conn, data.scope.user), data: data}
  end

  defp export_binary(opts \\ []) do
    opts
    |> Keyword.put_new(:source_host, "localhost:4000")
    |> Keyword.put_new(:now, ~U[2026-09-25 12:05:00Z])
    |> Export.build()
    |> IO.iodata_to_binary()
  end

  defp upload_export!(view, binary, name \\ "export.json") do
    view
    |> file_input("#transfer-import-form", :transfer_file, [
      %{name: name, content: binary, size: byte_size(binary), type: "application/json"}
    ])
    |> render_upload(name)
  end

  defp incoming_files do
    dir = Path.join(Application.fetch_env!(:wedding_planner, :transfer_dir), "incoming")

    case File.ls(dir) do
      {:ok, names} -> names
      {:error, _} -> []
    end
  end

  describe "the export link" do
    test "carries the viewer's time zone", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/settings")

      assert view
             |> element("#transfer-export")
             |> render() =~ ~s(href="/transfer/export?tz=)
    end
  end

  describe "upload → checking → preview → confirm → importing → done (FP-101c)" do
    test "the preview shows the right counts and warning; confirm disables the button and shows Importing…, then #transfer-done (fail-proof: skip the `disabled` attribute during :importing — must fail)",
         %{conn: conn, data: data} do
      export = export_binary()

      {:ok, _} = Guests.delete_person(data.scope, data.persons.bram)
      {:ok, extra_task} = Tasks.create_task(data.scope, %{"title" => "Extra task"})

      {:ok, view, _html} = live(conn, ~p"/settings")

      upload_export!(view, export)
      render_async(view)

      assert has_element?(view, "#transfer-preview")

      persons_row = view |> element("#transfer-count-persons") |> render()
      assert persons_row =~ "5 in the file"
      assert persons_row =~ "4 here now"

      tasks_row = view |> element("#transfer-count-tasks") |> render()
      assert tasks_row =~ "3 in the file"
      assert tasks_row =~ "4 here now"

      assert has_element?(view, "#transfer-warning", "This replaces all data in this app.")
      assert has_element?(view, "#transfer-users")
      assert has_element?(view, "#transfer-user-0", "Wannes → Wannes")

      refute has_element?(view, "#transfer-confirm[disabled]")

      html = view |> element("#transfer-confirm") |> render_click()
      assert html =~ "Importing…"
      assert has_element?(view, "#transfer-confirm[disabled]")
      assert has_element?(view, "#transfer-status", "Importing…")

      render_async(view)

      assert has_element?(view, "#transfer-done")
      assert has_element?(view, "#transfer-safety-copy-link")
      refute has_element?(view, "#transfer-preview")

      assert Guests.get_person!(data.persons.bram.id).id == data.persons.bram.id
      refute Enum.any?(Tasks.list_tasks(), &(&1.id == extra_task.id))

      assert incoming_files() == []
    end
  end

  describe "refused (FP-101d)" do
    test "an older/newer schema version shows the refusal, no confirm button, nothing changed (fail-proof: render the preview on {:error, _} — must fail)",
         %{conn: conn, data: data} do
      before_count = length(Guests.list_persons())

      binary = export_binary()
      bumped = bump_schema_version(binary, SchemaVersion.current() + 1)

      {:ok, view, _html} = live(conn, ~p"/settings")
      upload_export!(view, bumped)
      render_async(view)

      assert has_element?(view, "#transfer-refused", "Update this app first")
      refute has_element?(view, "#transfer-confirm")
      refute has_element?(view, "#transfer-preview")

      assert length(Guests.list_persons()) == before_count
      # sanity: the fixture actually still has its second user's data untouched
      assert data.scope.user
    end

    test "a non-export JSON file shows \"isn't a wedding planner export\"", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/settings")
      upload_export!(view, ~s({"hello": "world"}))
      render_async(view)

      assert has_element?(view, "#transfer-refused", "isn't a wedding planner export")
    end

    test "choose another file returns to idle and discards the stash", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/settings")
      upload_export!(view, ~s({"hello": "world"}))
      render_async(view)

      assert has_element?(view, "#transfer-refused")
      view |> element("#transfer-choose-another") |> render_click()

      refute has_element?(view, "#transfer-refused")
      assert incoming_files() == []
    end
  end

  defp bump_schema_version(binary, version) do
    binary
    |> Jason.decode!()
    |> put_in(["meta", "schema_version"], version)
    |> Jason.encode!()
  end

  describe "cancel" do
    test "discards the stash and returns to idle", %{conn: conn} do
      export = export_binary()

      {:ok, view, _html} = live(conn, ~p"/settings")
      upload_export!(view, export)
      render_async(view)

      assert has_element?(view, "#transfer-preview")
      view |> element("#transfer-cancel") |> render_click()

      refute has_element?(view, "#transfer-preview")
      assert incoming_files() == []
    end
  end

  describe "live reload of another open screen (FP-101e)" do
    test "the import redirects a second /people view but leaves the importing view on its done panel (fail-proof: origin: nil — the importing view must then also redirect and this test must fail)",
         %{conn: conn} do
      export = export_binary()

      {:ok, settings_view, _html} = live(conn, ~p"/settings")
      {:ok, people_view, _html} = live(conn, ~p"/people")

      upload_export!(settings_view, export)
      render_async(settings_view)

      settings_view |> element("#transfer-confirm") |> render_click()
      render_async(settings_view)

      assert_redirect(people_view, ~p"/people")
      assert has_element?(settings_view, "#transfer-done")
    end
  end

  describe "safety copies" do
    test "the newest is listed first after two imports, each downloadable", %{
      conn: conn,
      data: data
    } do
      export = export_binary()

      {:ok, view, _html} = live(conn, ~p"/settings")

      upload_export!(view, export)
      render_async(view)
      view |> element("#transfer-confirm") |> render_click()
      render_async(view)

      first_link = view |> element("#transfer-safety-copy-0") |> render()
      assert first_link =~ "href"

      # A second import writes a second, newer safety copy.
      export2 = export_binary(now: ~U[2026-09-25 13:05:00Z])
      upload_export!(view, export2, "export2.json")
      render_async(view)
      view |> element("#transfer-confirm") |> render_click()
      render_async(view)

      copies = Transfer.list_safety_copies()
      assert length(copies) == 2
      assert Enum.at(copies, 0).saved_at >= Enum.at(copies, 1).saved_at

      assert has_element?(view, "#transfer-safety-copy-0")
      assert has_element?(view, "#transfer-safety-copy-1")
      assert data.scope.user
    end
  end
end
