defmodule WeddingPlannerWeb.Components.ExportComponentsTest do
  @moduledoc """
  `WeddingPlannerWeb.Components.ExportComponents.export_link/1` (`XC-30`, `DR-87`, task
  94) — the one "Export CSV" link every owning screen renders. Exercised as a pure
  function component (`Phoenix.LiveViewTest.render_component/2`), independent of any
  LiveView route; each of the seven screens' own LiveView tests prove the link actually
  appears in place on that screen, carrying that screen's own `@time_zone` (`FP-94a`,
  `FP-94b`).
  """
  use ExUnit.Case, async: true
  use Phoenix.Component

  import Phoenix.LiveViewTest
  import WeddingPlannerWeb.Components.ExportComponents

  # LazyHTML.filter/2 only matches *root* nodes of the fragment; query/2 searches
  # descendants — the same idiom `WeddingPlannerWeb.CoreComponentsTest` uses.
  defp find(html, selector), do: html |> LazyHTML.from_fragment() |> LazyHTML.query(selector)

  test "id'd '#export-<kind>' link to /exports/<kind>, carrying ?tz= and download" do
    html = render_component(&export_link/1, %{kind: "persons", time_zone: "Europe/Brussels"})

    link = find(html, "#export-persons")
    assert [href] = LazyHTML.attribute(link, "href")
    assert String.starts_with?(href, "/exports/persons?tz=")
    assert href =~ "Europe" and href =~ "Brussels"
    assert LazyHTML.attribute(link, "download") == [""]
  end

  # FP-94b: switching this component to `<.link navigate={...}>` (a LiveView
  # navigation) instead of a plain `href` would add a `data-phx-link` attribute —
  # asserted absent here so a regression back to `navigate`/`patch` fails this test.
  test "never a LiveView navigation: no data-phx-link attribute" do
    html = render_component(&export_link/1, %{kind: "budget", time_zone: "UTC"})

    link = find(html, "#export-budget")
    assert LazyHTML.attribute(link, "data-phx-link") == []
    assert LazyHTML.attribute(link, "navigate") == []
    assert LazyHTML.attribute(link, "patch") == []
  end

  test "the kind selects both the DOM id and the export path" do
    html = render_component(&export_link/1, %{kind: "offers", time_zone: "UTC"})

    link = find(html, "#export-offers")
    assert [href] = LazyHTML.attribute(link, "href")
    assert String.starts_with?(href, "/exports/offers?tz=")
    refute Enum.empty?(find(html, "#export-offers .hero-arrow-down-tray"))
  end

  test "the label defaults to 'Export CSV' but can be overridden" do
    default_html = render_component(&export_link/1, %{kind: "tasks", time_zone: "UTC"})
    assert LazyHTML.text(find(default_html, "#export-tasks")) =~ "Export CSV"

    custom_html =
      render_component(&export_link/1, %{kind: "tasks", time_zone: "UTC", label: "Download"})

    assert LazyHTML.text(find(custom_html, "#export-tasks")) =~ "Download"
    refute LazyHTML.text(find(custom_html, "#export-tasks")) =~ "Export CSV"
  end
end
