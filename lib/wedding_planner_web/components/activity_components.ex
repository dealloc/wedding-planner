defmodule WeddingPlannerWeb.ActivityComponents do
  @moduledoc """
  The one activity-log rendering idiom (`activity_entry/1`) and the reusable per-entity
  history component (`entity_history/1`) task 20 builds for every later detail view to
  reuse (`docs/04-cross-cutting.md` `XC-10` through `XC-13`).

  Read-only (`XC-13`): neither component ever renders an edit, delete or undo
  affordance, and never will.
  """
  use Phoenix.Component

  alias WeddingPlanner.Log
  alias WeddingPlannerWeb.Format

  @doc """
  Renders one activity entry's line (`XC-10`): the description, the resolved entity
  reference (a navigable link when `WeddingPlanner.Log.resolve/1` returns
  `{:link, label, path}`, plain text for `{:text, label}`, nothing for a bulk summary's
  `nil`), the acting user, and the UTC timestamp converted to the viewer's time zone and
  formatted `dd/mm/yyyy` (`NFR-22`, `NFR-23`, via `WeddingPlannerWeb.Format`).

  `entry.user` must already be preloaded (every `WeddingPlanner.Log.Query` function that
  returns entries preloads it).
  """
  attr :id, :string, required: true
  attr :entry, :any, required: true, doc: "a WeddingPlanner.Log.Entry.t(), :user preloaded"
  attr :time_zone, :string, default: nil

  def activity_entry(assigns) do
    assigns = assign(assigns, :resolved, Log.resolve(assigns.entry))

    ~H"""
    <div id={@id} class="flex flex-wrap items-baseline justify-between gap-x-4 gap-y-1">
      <p class="text-sm text-ink">
        {@entry.description}
        <%= case @resolved do %>
          <% {:link, label, path} -> %>
            <.link navigate={path} class="font-medium text-accent hover:underline">{label}</.link>
          <% {:text, label} -> %>
            <span class="text-ink-soft">{label}</span>
          <% nil -> %>
        <% end %>
      </p>
      <p class="shrink-0 text-xs text-ink-faint">
        <span class="font-medium text-ink-soft">{user_label(@entry)}</span>
        <span aria-hidden="true">&middot;</span>
        <time datetime={DateTime.to_iso8601(@entry.inserted_at)} class="tabular-nums">
          {Format.datetime(@entry.inserted_at, @time_zone)}
        </time>
      </p>
    </div>
    """
  end

  defp user_label(%{user: %{display_name: name}}) when is_binary(name), do: name
  defp user_label(_entry), do: "Unknown user"

  @doc """
  Reusable per-entity activity history (task 20). This is the interface every later
  detail view (offers, invoices, persons, tasks, …) reuses to show "this entity's
  history" — its exact contract, quoted below, is what matters, not the markup.

  ## Contract

  This is a **plain, stateless function component**. It does no data fetching and no
  PubSub subscribing of its own — that stays the host LiveView's job, so the component
  never pulls `Ecto`/`WeddingPlanner.Repo`/`WeddingPlanner.Realtime` concerns in and stays
  trivially reusable from anywhere.

  Attrs:

    * `:id` (required) — unique DOM id for the container; every entry row and the empty
      state are namespaced under it (`"\#{id}-entry-\#{entry.id}"`, `"\#{id}-empty"`).
    * `:entity` (required) — `{type, id}`, the same pair
      `WeddingPlanner.Log.entry/3`/`WeddingPlanner.Log.Query.for_entity/2` take, e.g.
      `{:invoice, invoice.id}`. Not used to filter — the `:entries` you pass are trusted
      to already be scoped to it — only to build the empty-state label.
    * `:entries` (required) — `WeddingPlanner.Log.Entry.t()` list for this entity,
      **including bulk-action children** (`XC-12` — a child entry carries the same
      `entity_type`/`entity_id` as a standalone one, so
      `WeddingPlanner.Log.Query.for_entity/2` returns both without special-casing),
      newest first, `:user` preloaded.
    * `:time_zone` — the viewer's IANA zone (`@time_zone`, assigned by
      `WeddingPlannerWeb.Live.TimeZoneHook`), forwarded to
      `WeddingPlannerWeb.Format.datetime/2` (`NFR-22`).
    * `:empty_message` — shown when `:entries` is `[]`; defaults to "No activity yet."

  ## Host LiveView pattern

  Fetch once (mount or `handle_params`), subscribe to the collection topic, and filter
  each live-broadcast entry down to this one entity yourself — `WeddingPlanner.Realtime`
  has no per-referenced-entity topic, only the collection topic every resource shares:

      defmodule MyAppWeb.Live.InvoiceLive do
        use MyAppWeb, :live_view

        on_mount {WeddingPlannerWeb.Live.TimeZoneHook, :default}

        alias WeddingPlanner.Log.Query
        alias WeddingPlanner.Realtime

        def mount(%{"id" => id}, _session, socket) do
          if connected?(socket), do: Realtime.subscribe(:activity_entry)

          {:ok, assign(socket, :activity_entries, Query.for_entity(:invoice, id))}
        end

        def handle_info({Realtime, :activity_entry, {:created, entry}}, socket) do
          %{invoice: invoice} = socket.assigns

          if entry.entity_type == "invoice" and entry.entity_id == invoice.id do
            entry = Query.preload_user(entry)
            {:noreply, update(socket, :activity_entries, &[entry | &1])}
          else
            {:noreply, socket}
          end
        end

        def render(assigns) do
          ~H\"""
          <.entity_history
            id="invoice-history"
            entity={{:invoice, @invoice.id}}
            entries={@activity_entries}
            time_zone={@time_zone}
          />
          \"""
        end
      end

  Per `DR-21`/`XC-02`'s "no concurrent-edit indicator" decision, a live-arrived entry is
  simply prepended to the list — no highlight, badge, flash or animation calls attention
  to the fact that it is new.
  """
  attr :id, :string, required: true
  attr :entity, :any, required: true, doc: "{type, id} — see moduledoc"
  attr :entries, :list, required: true
  attr :time_zone, :string, default: nil
  attr :empty_message, :string, default: nil

  def entity_history(assigns) do
    assigns = assign_new(assigns, :empty_message, fn -> default_empty_message(assigns.entity) end)

    ~H"""
    <div id={@id} class="divide-y divide-line">
      <p :if={@entries == []} id={"#{@id}-empty"} class="py-4 text-sm text-ink-faint">
        {@empty_message}
      </p>
      <div :for={entry <- @entries} id={"#{@id}-entry-#{entry.id}"} class="py-3">
        <.activity_entry id={"#{@id}-entry-#{entry.id}-row"} entry={entry} time_zone={@time_zone} />
      </div>
    </div>
    """
  end

  defp default_empty_message({type, _id}) do
    "No activity yet for this #{Phoenix.Naming.humanize(type) |> String.downcase()}."
  end
end
