defmodule WeddingPlannerWeb.ReferencesComponentTest do
  @moduledoc """
  `WeddingPlannerWeb.ReferencesComponent` (task 40, `DR-31`) — list, add-file, add-URL,
  rename and delete, `docs/04-cross-cutting.md` `XC-20`–`XC-24`, `XC-40`.

  Exercised through `test/support/references_host_live.ex` via
  `Phoenix.LiveViewTest.live_isolated/3`, the documented host pattern (`DR-28`'s
  stand-in owner, `WeddingPlanner.ReferenceFixtures.owner/0` — no dev route writes
  ownerless rows). `async: false`: uploads write real files under `:uploads_dir`, cleaned
  up by `ReferenceFixtures.track_uploads_dir/0`.
  """
  use WeddingPlannerWeb.ConnCase, async: false

  import Phoenix.LiveViewTest
  import WeddingPlanner.ReferenceFixtures

  alias WeddingPlanner.Accounts.Scope
  alias WeddingPlanner.Accounts.User
  alias WeddingPlanner.References
  alias WeddingPlanner.References.Storage
  alias WeddingPlanner.Repo
  alias WeddingPlannerWeb.ReferencesHostLiveTestSupport, as: HostLive

  setup do
    user = %User{} |> User.changeset(%{display_name: "Wannes"}) |> Repo.insert!()

    %{
      scope: Scope.for_user(user),
      owner: owner(),
      before: track_uploads_dir()
    }
  end

  defp start_view!(ctx) do
    {:ok, view, _html} =
      live_isolated(build_conn(), HostLive,
        session: %{"owner" => ctx.owner, "scope" => ctx.scope}
      )

    view
  end

  defp find(html, selector), do: html |> LazyHTML.from_fragment() |> LazyHTML.query(selector)
  defp attr(html, selector, name), do: html |> find(selector) |> LazyHTML.attribute(name)

  defp last_reference(ctx), do: ctx.owner |> References.list_references() |> List.last()

  test "the file input carries both MIME types and extensions, and no capture attribute (DR-29)",
       ctx do
    view = start_view!(ctx)
    html = render(view)

    accept = html |> attr("#refs-file-input input", "accept") |> List.first()
    assert accept =~ "image/jpeg"
    assert accept =~ "application/pdf"
    assert accept =~ ".pdf"
    assert accept =~ ".jpg"

    assert html |> attr("#refs-file-input input", "capture") == []
  end

  test "uploading a PNG with a blank label creates a reference shown as an image thumbnail",
       ctx do
    view = start_view!(ctx)
    content = bytes(:png)

    avatar =
      file_input(view, "#refs-upload-form", :file, [
        %{name: "photo.png", content: content, size: byte_size(content), type: "image/png"}
      ])

    assert render_upload(avatar, "photo.png") =~ "100"

    view
    |> element("#refs-upload-form")
    |> render_submit(%{"file" => %{"label" => ""}})

    reference = last_reference(ctx)
    assert reference.label == "photo.png"
    assert reference.content_type == "image/png"

    html = render(view)
    assert find(html, "#refs-ref-#{reference.id} img") != []

    assert attr(html, "#refs-ref-#{reference.id} img", "src") == [
             "/references/#{reference.id}/file"
           ]
  end

  test "uploading a PDF shows Open (new tab) and Download links with the right hrefs", ctx do
    view = start_view!(ctx)
    content = bytes(:pdf)

    avatar =
      file_input(view, "#refs-upload-form", :file, [
        %{name: "quote.pdf", content: content, size: byte_size(content), type: "application/pdf"}
      ])

    assert render_upload(avatar, "quote.pdf") =~ "100"

    view
    |> element("#refs-upload-form")
    |> render_submit(%{"file" => %{"label" => "Quote"}})

    reference = last_reference(ctx)
    assert reference.label == "Quote"
    html = render(view)

    open_selector = "#refs-ref-#{reference.id} a[href='/references/#{reference.id}/file']"
    assert attr(html, open_selector, "target") == ["_blank"]
    assert (attr(html, open_selector, "rel") |> List.first() || "") =~ "noopener"

    download_selector = "#refs-ref-#{reference.id} a[href='/references/#{reference.id}/download']"
    assert find(html, download_selector) != []
  end

  test "an HTML file lying about its type (.pdf name, application/pdf client type) is refused by the server sniff",
       ctx do
    view = start_view!(ctx)
    content = bytes(:html)
    before_count = length(References.list_references(ctx.owner))

    avatar =
      file_input(view, "#refs-upload-form", :file, [
        %{name: "quote.pdf", content: content, size: byte_size(content), type: "application/pdf"}
      ])

    assert render_upload(avatar, "quote.pdf") =~ "100"

    html =
      view
      |> element("#refs-upload-form")
      |> render_submit(%{"file" => %{"label" => ""}})

    assert html =~ "Only PDF, PNG, JPEG or WebP files"
    assert length(References.list_references(ctx.owner)) == before_count
  end

  test "an entry over the size limit is refused client-side and creates nothing", ctx do
    view = start_view!(ctx)
    before_count = length(References.list_references(ctx.owner))
    content = :binary.copy(<<0>>, Storage.max_bytes() + 1)

    avatar =
      file_input(view, "#refs-upload-form", :file, [
        %{name: "huge.png", content: content, size: byte_size(content), type: "image/png"}
      ])

    # LiveView's own upload preflight refuses an oversized entry before it is ever
    # tracked as a normal entry — `render_upload/3` returns the rejection directly
    # rather than rendered HTML.
    assert {:error, [[_ref, :too_large]]} = render_upload(avatar, "huge.png")
    assert has_element?(view, "#refs-upload-form", "Too large")
    assert length(References.list_references(ctx.owner)) == before_count
  end

  test "adding a URL creates a link item opening in a new tab", ctx do
    view = start_view!(ctx)

    view
    |> element("#refs-url-form")
    |> render_submit(%{"url" => %{"label" => "Venue site", "url" => "https://example.com/venue"}})

    reference = last_reference(ctx)
    assert reference.kind == :url
    html = render(view)

    link_selector = "#refs-ref-#{reference.id} a[href='https://example.com/venue']"
    assert attr(html, link_selector, "target") == ["_blank"]
    assert (attr(html, link_selector, "rel") |> List.first() || "") =~ "noopener"
    assert html =~ "example.com"
  end

  test "a javascript: URL is refused with a validation error and creates nothing", ctx do
    view = start_view!(ctx)
    before_count = length(References.list_references(ctx.owner))

    html =
      view
      |> element("#refs-url-form")
      |> render_submit(%{"url" => %{"label" => "Bad", "url" => "javascript:alert(1)"}})

    assert html =~ "must be an http" or html =~ "http:// or https://"
    assert length(References.list_references(ctx.owner)) == before_count
  end

  test "renaming a reference changes its label", ctx do
    view = start_view!(ctx)

    {:ok, reference} =
      References.create_url_reference(ctx.scope, ctx.owner, %{
        "label" => "Old label",
        "url" => "https://example.com"
      })

    view
    |> element("#refs-ref-#{reference.id}-rename")
    |> render_click()

    assert has_element?(view, "#refs-ref-#{reference.id}-rename")

    view
    |> element("#refs-ref-#{reference.id}-rename")
    |> render_submit(%{"reference" => %{"label" => "New label", "url" => reference.url}})

    assert has_element?(view, "#refs-ref-#{reference.id}", "New label")
    updated = References.get_reference!(reference.id)
    assert updated.label == "New label"
  end

  test "delete requires confirmation (target reaches the component); confirm removes the row, cancel keeps it",
       ctx do
    view = start_view!(ctx)

    {:ok, reference} =
      References.create_url_reference(ctx.scope, ctx.owner, %{
        "label" => "To delete",
        "url" => "https://example.com"
      })

    view
    |> element("#refs-ref-#{reference.id}-delete")
    |> render_click()

    assert has_element?(view, "#refs-ref-#{reference.id}-delete-confirm")

    # Cancel keeps it.
    view
    |> element("#refs-ref-#{reference.id}-delete-confirm-cancel")
    |> render_click()

    refute has_element?(view, "#refs-ref-#{reference.id}-delete-confirm")
    assert has_element?(view, "#refs-ref-#{reference.id}")
    assert References.get_reference(reference.id)

    # Confirm removes it.
    view
    |> element("#refs-ref-#{reference.id}-delete")
    |> render_click()

    view
    |> element("#refs-ref-#{reference.id}-delete-confirm-confirm")
    |> render_click()

    refute has_element?(view, "#refs-ref-#{reference.id}")
    refute References.get_reference(reference.id)
  end

  test "a reference created through the context (the other user) appears live, without interaction (XC-01)",
       ctx do
    view = start_view!(ctx)
    refute has_element?(view, "[id^='refs-ref-']")

    {:ok, reference} =
      References.create_url_reference(ctx.scope, ctx.owner, %{
        "label" => "Live-added",
        "url" => "https://example.com/live"
      })

    _ = :sys.get_state(view.pid)

    assert has_element?(view, "#refs-ref-#{reference.id}", "Live-added")
  end
end
