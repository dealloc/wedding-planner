defmodule WeddingPlannerWeb.CoreComponentsTest do
  @moduledoc """
  `WeddingPlannerWeb.CoreComponents.destructive_confirm/1` — the reusable
  destructive-confirmation panel required by `XC-40` (task 05 named it, task 22, the
  events exemplar slice, built it since nothing else did yet). Pure component tests,
  independent of any LiveView route — `WeddingPlanner.Events` is the first real caller,
  exercised through the events LiveView tests instead.
  """
  use ExUnit.Case, async: true
  use Phoenix.Component

  import Phoenix.LiveViewTest
  import WeddingPlannerWeb.CoreComponents

  # LazyHTML.filter/2 only matches *root* nodes of the fragment; query/2 searches
  # descendants, which is what every selector below needs.
  defp find(html, selector), do: html |> LazyHTML.from_fragment() |> LazyHTML.query(selector)
  defp present?(html, selector), do: not Enum.empty?(find(html, selector))
  defp text(html, selector), do: html |> find(selector) |> LazyHTML.text()

  describe "destructive_confirm/1 — XC-40" do
    test "renders the title, an optional body, and the confirm/cancel actions by DOM id" do
      html =
        render_component(&destructive_confirm/1, %{
          id: "delete-dinner",
          title: "Delete 'Dinner'?",
          body: "This cannot be undone.",
          confirm: "delete_confirmed",
          confirm_value: 42,
          cancel: "cancel_delete"
        })

      assert text(html, "#delete-dinner-title") =~ "Delete 'Dinner'?"
      assert html =~ "This cannot be undone."
      assert present?(html, "#delete-dinner-cancel")
      assert present?(html, "#delete-dinner-confirm")
      assert text(html, "#delete-dinner-confirm") =~ "Delete"
    end

    test "an empty affected list states there is nothing else to worry about" do
      html =
        render_component(&destructive_confirm/1, %{
          id: "delete-dinner",
          title: "Delete 'Dinner'?",
          confirm: "delete_confirmed",
          cancel: "cancel_delete"
        })

      assert text(html, "#delete-dinner-affected") =~ "Nothing else references this yet."
    end

    test "a non-empty affected list renders one row per reference type (EVT-05 shape)" do
      html =
        render_component(&destructive_confirm/1, %{
          id: "delete-dinner",
          title: "Delete 'Dinner'?",
          affected: [
            %{label: "2 invitations", count: 2},
            %{label: "1 offer line", count: 1}
          ],
          confirm: "delete_confirmed",
          cancel: "cancel_delete"
        })

      refute text(html, "#delete-dinner-affected") =~ "Nothing else references this yet."
      assert text(html, "#delete-dinner-affected") =~ "2 invitations"
      assert text(html, "#delete-dinner-affected") =~ "1 offer line"
    end

    test "the confirm button carries the confirm_value as phx-value-id" do
      html =
        render_component(&destructive_confirm/1, %{
          id: "delete-dinner",
          title: "Delete 'Dinner'?",
          confirm: "delete_confirmed",
          confirm_value: 42,
          cancel: "cancel_delete"
        })

      button = find(html, "#delete-dinner-confirm")
      assert LazyHTML.attribute(button, "phx-value-id") == ["42"]
      assert LazyHTML.attribute(button, "phx-click") == ["delete_confirmed"]
    end

    test "a custom confirm_label overrides the default 'Delete' wording" do
      html =
        render_component(&destructive_confirm/1, %{
          id: "revoke-passkey",
          title: "Revoke 'Old phone'?",
          confirm: "revoke_confirmed",
          cancel: "cancel_revoke",
          confirm_label: "Revoke"
        })

      assert text(html, "#revoke-passkey-confirm") =~ "Revoke"
      refute text(html, "#revoke-passkey-confirm") =~ "Delete"
    end
  end
end
