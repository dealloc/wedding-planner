defmodule WeddingPlanner.Log.EntityRef do
  @moduledoc """
  Resolves an activity entry's stored `{entity_type, entity_id}` polymorphic reference
  (`XC-10`) to something a view can render: a navigable link when the entity still
  exists and has a page, or plain text otherwise (the entity was deleted, or it exists
  but no page has been built for its type yet).

  ## Registering a new type

  No domain entities have pages yet (this task lands before every module slice), so the
  built-in resolvers below all degrade to plain text. A later slice registers its type
  by adding an entry to `@default_resolvers`, **or**, without touching this file, via
  application config:

      config :wedding_planner,
        log_entity_resolvers: %{
          "invoice" => &WeddingPlanner.Invoices.resolve_log_entity/1
        }

  merged on top of the defaults (`resolvers/0`), the app-config entry winning on a
  collision.

  A resolver is a 1-arity function taking the stored id and returning:

    * `{:ok, label, path}` — the entity exists and has a page at `path`
    * `{:ok, label, nil}` — the entity exists but its type has no page yet
    * `:error` — the entity no longer exists (deleted)

  In every case `resolve/2` returns something renderable; it never raises.
  """

  alias WeddingPlanner.Accounts.EnrollmentLink
  alias WeddingPlanner.Accounts.EnrollmentLinks
  alias WeddingPlanner.Accounts.Passkey
  alias WeddingPlanner.Accounts.User
  alias WeddingPlanner.Events.Event
  alias WeddingPlanner.Repo

  @type resolved ::
          {:link, label :: String.t(), path :: String.t()} | {:text, label :: String.t()}
  @type resolver :: (term() -> {:ok, String.t(), String.t() | nil} | :error)

  @doc """
  Resolves `{type, id}` to a `{:link, label, path}` or `{:text, label}` tuple. Always
  succeeds, including for an unregistered type or a deleted entity — that degradation is
  the point (`XC-10`: "an entry for a deleted entity still renders").
  """
  @spec resolve(String.t(), term()) :: resolved()
  def resolve(type, id) when is_binary(type) do
    case Map.fetch(resolvers(), type) do
      {:ok, resolver} -> apply_resolver(resolver, type, id)
      :error -> {:text, fallback_label(type, id)}
    end
  end

  defp apply_resolver(resolver, type, id) do
    case resolver.(id) do
      {:ok, label, nil} -> {:text, label}
      {:ok, label, path} when is_binary(path) -> {:link, label, path}
      :error -> {:text, fallback_label(type, id)}
    end
  end

  defp fallback_label(type, id) do
    "#{Phoenix.Naming.humanize(type)} ##{id}"
  end

  @doc false
  @spec resolvers() :: %{optional(String.t()) => resolver()}
  def resolvers do
    Map.merge(
      default_resolvers(),
      Application.get_env(:wedding_planner, :log_entity_resolvers, %{})
    )
  end

  # `"event"` (task 22) is the first type with a real page — every other built-in
  # resolver below still reports `nil` path (the "exists but no page yet" branch of
  # `XC-10`) until its own slice lands.
  defp default_resolvers do
    %{
      "user" => &resolve_user/1,
      "passkey" => &resolve_passkey/1,
      "enrollment_link" => &resolve_enrollment_link/1,
      "settings" => &resolve_settings/1,
      "event" => &resolve_event/1,
      "task" => &WeddingPlanner.Tasks.resolve_log_entity/1,
      "person" => &WeddingPlanner.Guests.resolve_person_log_entity/1,
      "group" => &WeddingPlanner.Guests.resolve_group_log_entity/1,
      "category" => &WeddingPlanner.Categories.resolve_category_log_entity/1,
      "service" => &WeddingPlanner.Categories.resolve_service_log_entity/1,
      "offer" => &WeddingPlanner.Offers.resolve_log_entity/1,
      "headcount_preset" => &WeddingPlanner.Presets.resolve_log_entity/1,
      "invoice" => &WeddingPlanner.Invoices.resolve_log_entity/1,
      "circle" => &WeddingPlanner.Seating.resolve_circle_log_entity/1,
      "seating_rule" => &WeddingPlanner.Seating.resolve_rule_log_entity/1,
      "seating_table" => &WeddingPlanner.Seating.resolve_table_log_entity/1
    }
  end

  defp resolve_user(id) do
    case Repo.get(User, id) do
      nil -> :error
      user -> {:ok, user.display_name, nil}
    end
  end

  defp resolve_passkey(id) do
    case Repo.get(Passkey, id) do
      nil -> :error
      passkey -> {:ok, passkey.name, nil}
    end
  end

  # A human flavour label ("Invitation link", "Device link", "Recovery link") rather
  # than the raw stored `flavour` string ("user_invitation") — reuses
  # `EnrollmentLinks.flavour_label/1` so this and the activity log's own action wording
  # (`EnrollmentLinksLive.log_description/3`) never drift apart.
  defp resolve_enrollment_link(id) do
    case Repo.get(EnrollmentLink, id) do
      nil -> :error
      link -> {:ok, "#{link |> EnrollmentLinks.flavour_label() |> String.capitalize()} link", nil}
    end
  end

  # The Settings singleton (task 21) is the one entity that is never deleted (its row is
  # created on first access and never removed), so this always resolves — but it still
  # goes through Repo.get rather than assuming id 1, in case that ever changes.
  defp resolve_settings(id) do
    case Repo.get(WeddingPlanner.Settings, id) do
      nil -> :error
      _settings -> {:ok, "Settings", "/settings"}
    end
  end

  defp resolve_event(id) do
    case Repo.get(Event, id) do
      nil -> :error
      event -> {:ok, event.name, "/events/#{event.id}/edit"}
    end
  end
end
