defmodule WeddingPlannerWeb.DisplayComponentsTest do
  use ExUnit.Case, async: true
  use Phoenix.Component

  import Phoenix.LiveViewTest
  import WeddingPlannerWeb.DisplayComponents

  # Component-level tests, independent of the scratch route/LiveView (task 06's own
  # `/proto/display`, uncommitted and removed before merge) — these must keep passing
  # whether or not that scratch page exists in the tree. Assertions go through
  # LazyHTML element selectors rather than raw HTML, per AGENTS.md.

  # LazyHTML.filter/2 only matches *root* nodes of the fragment; query/2 is the one
  # that searches descendants, which is what every selector below needs.
  defp find(html, selector), do: html |> LazyHTML.from_fragment() |> LazyHTML.query(selector)
  defp present?(html, selector), do: not Enum.empty?(find(html, selector))
  defp text(html, selector), do: html |> find(selector) |> LazyHTML.text()

  describe "formula/1 — CST-34, BUD-08, NFR-32, NFR-14" do
    # Figures borrowed from the CST-36 Caterer C worked example, as hand-written display
    # strings only. Deliberately NOT tagged `example:` — it exercises the renderer, not the
    # cost engine, so X3's coverage audit must not count it as implementing that example.
    test "renders the total, every step in order, and the standing rounding caption" do
      html =
        render_component(&formula/1, %{
          id: "f",
          total_label: "Total (Likely)",
          total: "€ 7.641,50",
          steps: [
            %{label: "Preset used", value: "Likely"},
            %{
              label: "Dinner catering, adults — 72 × € 60,00 excl., 12% VAT",
              value: "€ 4.838,40"
            },
            %{label: "Dinner catering, children — 6 × € 30,00 excl., 12% VAT", value: "€ 201,60"},
            %{label: "Drinks — 78 × € 25,00 excl., 21% VAT", value: "€ 2.359,50"},
            %{label: "Travel — minimum charge applied, 21% VAT", value: "€ 242,00"}
          ]
        })

      assert text(html, "#f-total") =~ "€ 7.641,50"

      assert text(html, "#f-step-0") =~ "Preset used"
      assert text(html, "#f-step-0") =~ "Likely"
      assert text(html, "#f-step-4") =~ "Travel"

      for index <- 0..4, do: assert(present?(html, "#f-step-#{index}"))
      refute present?(html, "#f-step-5")

      assert text(html, "#f-caption") =~ "may not sum exactly to it"
    end

    test "the disclosure is a native <details>/<summary> — zero JavaScript required" do
      html = render_component(&formula/1, %{id: "f", total: "€ 1,00", steps: []})

      assert present?(html, "details#f-disclosure summary")
    end

    test "an empty steps list still renders the caption rather than omitting it" do
      html = render_component(&formula/1, %{id: "f", total: "€ 0,00", steps: []})

      assert present?(html, "#f-caption")
    end
  end

  describe "range/1 — BUD-04, CST-53, vision goal 2" do
    test "renders both the minimum and maximum bound" do
      html =
        render_component(&range/1, %{
          id: "r",
          label: "Total across default presets",
          minimum: "€ 7.000,00",
          maximum: "€ 8.212,90"
        })

      assert text(html, "#r-minimum") =~ "€ 7.000,00"
      assert text(html, "#r-maximum") =~ "€ 8.212,90"
    end
  end

  describe "preset_selector/1 — HC-08, HC-10, DR-54, D-31" do
    @presets [%{id: 1, name: "Minimum"}, %{id: 2, name: "Likely"}, %{id: 3, name: "Maximum"}]

    test "renders one chip per stored preset, in the given order, by id" do
      html = render_component(&preset_selector/1, %{id: "p", presets: @presets, selected: 2})

      assert present?(html, "input#p-option-1")
      assert present?(html, "input#p-option-2")
      assert present?(html, "input#p-option-3")
      assert present?(html, "input#p-option-1[value='1']")
    end

    test "the selected id's chip is checked, no other" do
      html = render_component(&preset_selector/1, %{id: "p", presets: @presets, selected: 2})

      assert present?(html, "input#p-option-2[checked]")
      refute present?(html, "input#p-option-1[checked]")
      refute present?(html, "input#p-option-3[checked]")
    end

    test "selected is compared by string, so a string form of the id also matches" do
      html = render_component(&preset_selector/1, %{id: "p", presets: @presets, selected: "3"})

      assert present?(html, "input#p-option-3[checked]")
    end

    test "an id selected by no preset (deleted, or no selection yet) checks nothing" do
      html = render_component(&preset_selector/1, %{id: "p", presets: @presets, selected: nil})

      refute present?(html, "input[checked]")
    end

    test "a preset's full name is never dropped, even when visually truncated" do
      long_name = "A genuinely very long preset name that should be visually truncated"
      presets = [%{id: 1, name: long_name}]

      html = render_component(&preset_selector/1, %{id: "p", presets: presets, selected: 1})

      assert String.trim(text(html, "#p-option-1 + span")) == long_name
      assert present?(html, "#p [title='#{long_name}']")
    end

    test "renders no phx-click or phx-change of its own — selection never leaves the DOM
          unless a caller deliberately wires that up" do
      html = render_component(&preset_selector/1, %{id: "p", presets: @presets, selected: 2})

      refute html =~ "phx-click"
      refute html =~ "phx-change"
    end

    defp two_presets(assigns) do
      ~H"""
      <.preset_selector id="preset-a" presets={@presets} selected={1} />
      <.preset_selector id="preset-b" presets={@presets} selected={3} />
      """
    end

    test "two instances on one page hold different values independently" do
      html = render_component(&two_presets/1, %{presets: @presets})

      # Distinct radio-group names (derived from each instance's own id) make this a
      # native-HTML guarantee, not something this module has to arrange: instance A is
      # on Minimum, instance B on Maximum, and selecting within one native radio group
      # can never affect the other's `name`.
      assert present?(html, "input#preset-a-option-1[checked]")
      assert present?(html, "input#preset-b-option-3[checked]")
      refute present?(html, "input#preset-a-option-3[checked]")
      refute present?(html, "input#preset-b-option-1[checked]")

      assert present?(html, "input[name='preset-a-preset']")
      assert present?(html, "input[name='preset-b-preset']")
    end
  end

  describe "gap_severity/1 — CST-25, CST-54, XC-42" do
    test "must-have gap renders the prominent solid treatment with its icon" do
      html = render_component(&gap_severity/1, %{id: "g", severity: :must_have})

      assert present?(html, "#g[data-severity=must_have]")
      assert present?(html, "#g .hero-exclamation-triangle")
      assert text(html, "#g") =~ "Must-have gap"
    end

    test "nice-to-have gap renders the subtle plain-text treatment, no icon and no pill" do
      html = render_component(&gap_severity/1, %{id: "g", severity: :nice_to_have})

      assert present?(html, "#g[data-severity=nice_to_have]")
      refute present?(html, "#g .hero-exclamation-triangle")
      refute present?(html, "#g .hero-no-symbol")
      refute html =~ "rounded-chip"
      assert text(html, "#g") =~ "Nice-to-have gap"
    end

    test "unknown gap renders the neutral dashed-border 'ask the vendor' treatment" do
      html = render_component(&gap_severity/1, %{id: "g", severity: :unknown})

      assert present?(html, "#g[data-severity=unknown]")
      refute present?(html, "#g .hero-exclamation-triangle")
      refute present?(html, "#g .hero-no-symbol")
      assert text(html, "#g") =~ "Ask the vendor"
    end

    test "invalid line reuses the prominent treatment with a different icon (XC-42)" do
      html = render_component(&gap_severity/1, %{id: "g", severity: :invalid})

      assert present?(html, "#g[data-severity=invalid]")
      assert present?(html, "#g .hero-no-symbol")
      refute present?(html, "#g .hero-exclamation-triangle")
      assert text(html, "#g") =~ "Invalid line"
    end

    test "a custom label overrides the default text" do
      html = render_component(&gap_severity/1, %{id: "g", severity: :unknown, label: "TBD"})

      assert text(html, "#g") =~ "TBD"
      refute text(html, "#g") =~ "Ask the vendor"
    end
  end

  describe "status_pill/1 — visually distinct from gap_severity/1" do
    test "renders each tone with the soft (not solid) background and no icon" do
      for {tone, label} <- [
            {:info, "Invited"},
            {:good, "Accepted"},
            {:warn, "Maybe"},
            {:bad, "No"},
            {:neutral, "Considering"}
          ] do
        html = render_component(&status_pill/1, %{id: "s", label: label, tone: tone})

        assert present?(html, "#s[data-tone=#{tone}]")
        assert text(html, "#s") =~ label
        refute present?(html, "#s .hero-exclamation-triangle")
        refute present?(html, "#s .hero-no-symbol")
      end
    end
  end
end
