defmodule WeddingPlannerWeb.ReferencesComponent do
  @moduledoc """
  The reusable references panel (task 40, `DR-31`): list, add-file, add-URL, rename and
  delete for one owner's `WeddingPlanner.References` (`docs/04-cross-cutting.md`
  `XC-20`–`XC-24`).

  ## Why a `LiveComponent` (`DR-31`)

  `AGENTS.md` says to avoid LiveComponents unless there is a strong, specific need. This
  is that exception: the panel owns an upload config, an add-file form, an add-URL form,
  per-reference rename state and a delete confirmation — roughly eight event handlers —
  and must drop into at least two hosts (the offer view, C2; the invoice view, B2)
  without each host re-implementing all of it. `AGENTS.md`'s own LiveView guidelines
  (`<.live_file_input>`, `allow_upload/3`) only work inside something that owns upload
  state across re-renders, which a plain function component cannot do.

  ## The owner contract (`DR-28`)

  This component knows nothing about offers or invoices. It takes a
  `WeddingPlanner.References.Owner` (`:owner`) and does not fetch its own references —
  the **host** loads them with `WeddingPlanner.References.list_references/1`, subscribes
  to `WeddingPlanner.Realtime.topic(:reference)`, and re-renders on every broadcast
  (`XC-01`); this component always trusts the `:references` assign it is given rather
  than caching or re-fetching. `test/support/references_host_live.ex` is the minimal
  host this is exercised through (`live_isolated/3`) until C2 mounts it for real — there
  is no dev-only route (`DR-28`: it would write ownerless rows and break B2's CHECK).

  ## Assigns in

    * `:id` (required) — the DOM id every other id is derived from:
      `"\#{id}-list"`, `"\#{id}-ref-<ref id>"`, `"\#{id}-upload-form"`,
      `"\#{id}-file-input"`, `"\#{id}-label"`, `"\#{id}-upload-submit"`,
      `"\#{id}-url-form"`, `"\#{id}-url-label"`, `"\#{id}-url"`, `"\#{id}-url-submit"`,
      `"\#{id}-ref-<ref id>-rename"`, `"\#{id}-ref-<ref id>-delete"`,
      `"\#{id}-ref-<ref id>-delete-confirm"`.
    * `:owner` (required) — a `WeddingPlanner.References.Owner.t()`.
    * `:references` (required) — the owner's current `WeddingPlanner.References.Reference.t()`
      list (oldest first), as `WeddingPlanner.References.list_references/1` returns it.
      Re-streamed (`reset: true`) on every update, so the host is always the source of
      truth — this component never mutates its own copy of the list.
    * `:current_scope` (required) — a `WeddingPlanner.Accounts.Scope.t()`, forwarded to
      every `WeddingPlanner.References` call.
    * `:time_zone` (optional, default `nil`) — forwarded to
      `WeddingPlannerWeb.Format.datetime/2` for the "Added ..." meta line
      (`NFR-21`/`NFR-22`); `nil` falls back to the stored app default, exactly like
      `WeddingPlannerWeb.ActivityComponents.entity_history/1`'s own `:time_zone` attr.
      Not part of `DR-31`'s four required assigns — added so this component never has to
      invent its own date formatting (`WeddingPlannerWeb.Format`'s moduledoc: "the single
      display-formatting layer"). Flagged for whoever wires the first real host (C2): pass
      the real viewer time zone once `WeddingPlannerWeb.Live.TimeZoneHook` is available on
      that page.

  ## Uploads (`DR-29`)

  `allow_upload(:file, accept: ..., max_entries: 1, max_file_size: Storage.max_bytes())`
  in `mount/1`. `accept` carries both MIME types and extensions so Android's picker
  offers the camera alongside files; there is deliberately no `capture` attribute (it
  would force the camera and block choosing a PDF). The temp file is handed to
  `WeddingPlanner.References.create_file_reference/4` inside the
  `consume_uploaded_entries/3` callback, so it is only ever copied into storage once the
  upload is actually done.

  ### `<id>-file-input` is a wrapper, not the `<input>` itself

  `Phoenix.Component.live_file_input/1` does not let a caller override the `<input>`'s
  own `id` — it always renders `id={@upload.ref}` first, and that wins over any `id` a
  caller passes through its `:rest` global (confirmed empirically: passing `id=` to
  `<.live_file_input>` is silently dropped, not merged). `"\#{id}-file-input"` is
  therefore the id of the **wrapping `<div>`**; the underlying `<input type="file">` is
  reached in tests as its only `input` descendant. This does not affect
  `Phoenix.LiveViewTest.file_input/4`, which looks the upload up by form selector and
  upload name, never by the `<input>`'s DOM id.

  ## Rename (no nested `<form>`)

  The add-file form, the add-URL form and each reference's rename form are siblings —
  never nested inside one another. A reference's rename form only exists (in the DOM)
  while `@renaming_id == reference.id`; the view-mode "rename" button and the edit-mode
  `<.form>` share the same id (`"\#{id}-ref-<ref id>-rename"`) because they are
  mutually exclusive, exactly like `WeddingPlannerWeb.TaskComponents`' editor/row
  pattern. It commits on submit (Enter) or on blur — never per keystroke — via
  `Phoenix.LiveView.JS.dispatch("submit", to: ...)` on the label/URL inputs' `phx-blur`,
  which fires the form's own `phx-submit` handler.

  ## Delete (`XC-24`, `XC-40`)

  The delete button sets `@confirming_id`; `CoreComponents.destructive_confirm/1` renders
  with `target={@myself}` (`DR-31`'s reason for that component's new `:target` attr) so
  its Cancel/Delete buttons reach this component's own `handle_event/3` instead of
  falling through to the host, which has no matching clauses.

  ## Streams and "frozen" row content

  The list is a stream (`stream(:references, ...)` in `update/2`, `reset: true` on every
  external `:references` assign — the host is always the eventual source of truth). A
  stream item's rendered content does not get re-diffed just because some *other* assign
  referenced inside its template changes (`@renaming_id`, `@rename_form`,
  `@confirming_id`) — confirmed empirically, not just from the docs: toggling
  `@confirming_id` alone left the rendered HTML byte-for-byte unchanged until the
  affected row was re-streamed. So every handler that toggles rename/confirm state, or
  that mutates a reference, also calls `stream_insert/3` (or `stream_delete/3`) for the
  one row it touched — this is what the `AGENTS.md` streams guideline calls out under
  "When updating an assign that should change content inside any streamed item(s)". Its
  own action's `stream_insert`/`stream_delete` gives the acting browser immediate
  feedback; the host's `WeddingPlanner.Realtime.topic(:reference)` broadcast arrives
  moments later and fully re-streams (`reset: true`), which is also what makes the
  *other* viewer's browser see the same change (`XC-01`) and keeps this component from
  ever being the sole source of truth for what "the references" are (`XC-02`).
  """
  use WeddingPlannerWeb, :live_component

  alias WeddingPlanner.References
  alias WeddingPlanner.References.Reference
  alias WeddingPlanner.References.Storage
  alias WeddingPlannerWeb.Format

  @accept ~w(application/pdf image/png image/jpeg image/webp .pdf .png .jpg .jpeg .webp)

  @impl true
  def mount(socket) do
    {:ok,
     socket
     |> assign(:renaming_id, nil)
     |> assign(:rename_form, nil)
     |> assign(:confirming_id, nil)
     |> assign(:upload_error, nil)
     |> assign(:file_form, fresh_file_form())
     |> assign(:url_form, fresh_url_form())
     |> assign(:time_zone, nil)
     |> allow_upload(:file, accept: @accept, max_entries: 1, max_file_size: Storage.max_bytes())}
  end

  @impl true
  def update(%{references: references, id: id} = assigns, socket) do
    socket =
      socket
      |> assign(assigns)
      |> stream(:references, references, reset: true, dom_id: &"#{id}-ref-#{&1.id}")

    {:ok, socket}
  end

  # -- add file (XC-20, XC-21, DR-29) ---------------------------------------------------

  @impl true
  def handle_event("validate_upload", _params, socket) do
    {:noreply, assign(socket, :upload_error, nil)}
  end

  def handle_event("save_upload", params, socket) do
    label = params |> Map.get("file", %{}) |> Map.get("label", "")

    results =
      consume_uploaded_entries(socket, :file, fn %{path: path}, entry ->
        {:ok,
         References.create_file_reference(
           socket.assigns.current_scope,
           socket.assigns.owner,
           %{"label" => label},
           {path, entry.client_name}
         )}
      end)

    case results do
      [{:ok, reference}] ->
        {:noreply,
         socket
         |> assign(:upload_error, nil)
         |> assign(:file_form, fresh_file_form())
         |> stream_insert(:references, reference)}

      [{:error, reason}] ->
        {:noreply, assign(socket, :upload_error, error_message(reason))}

      [] ->
        {:noreply, assign(socket, :upload_error, "Choose a file to add.")}
    end
  end

  def handle_event("cancel_file_entry", %{"ref" => ref}, socket) do
    {:noreply, cancel_upload(socket, :file, ref)}
  end

  # -- add URL (XC-20, DR-29) ------------------------------------------------------------

  def handle_event("validate_url", %{"url" => params}, socket) do
    form =
      %Reference{}
      |> Reference.url_changeset(params)
      |> Map.put(:action, :validate)
      |> to_form(as: :url)

    {:noreply, assign(socket, :url_form, form)}
  end

  def handle_event("save_url", %{"url" => params}, socket) do
    case References.create_url_reference(
           socket.assigns.current_scope,
           socket.assigns.owner,
           params
         ) do
      {:ok, reference} ->
        {:noreply,
         socket |> assign(:url_form, fresh_url_form()) |> stream_insert(:references, reference)}

      {:error, changeset} ->
        {:noreply, assign(socket, :url_form, to_form(changeset, as: :url))}
    end
  end

  # -- rename (label, and URL for a url reference) ---------------------------------------

  # A stream item's rendered content is frozen once inserted: LiveView does not
  # re-diff it just because an *external* assign referenced inside its template
  # (`@renaming_id`, `@rename_form`, `@confirming_id`) changed. Every handler below that
  # toggles one of those must `stream_insert/3` the affected row again so the new
  # assigns actually reach the client (same rule as the `AGENTS.md` streams guideline:
  # "When updating an assign that should change content inside any streamed item(s),
  # you MUST re-stream the items along with the updated assign").

  def handle_event("start_rename", %{"id" => id}, socket) do
    case find_reference(socket, id) do
      nil ->
        {:noreply, socket}

      reference ->
        form = reference |> References.change_reference() |> to_form(as: :reference)

        {:noreply,
         socket
         |> assign(:renaming_id, reference.id)
         |> assign(:rename_form, form)
         |> stream_insert(:references, reference)}
    end
  end

  def handle_event("cancel_rename", _params, socket) do
    was_renaming = socket.assigns.renaming_id
    socket = socket |> assign(:renaming_id, nil) |> assign(:rename_form, nil)

    socket =
      case find_reference(socket, was_renaming) do
        nil -> socket
        reference -> stream_insert(socket, :references, reference)
      end

    {:noreply, socket}
  end

  def handle_event("save_rename", %{"reference" => params}, socket) do
    case find_reference(socket, socket.assigns.renaming_id) do
      nil ->
        {:noreply, socket |> assign(:renaming_id, nil) |> assign(:rename_form, nil)}

      reference ->
        socket.assigns.current_scope
        |> References.update_reference(socket.assigns.owner, reference, params)
        |> case do
          {:ok, updated} ->
            {:noreply,
             socket
             |> assign(:renaming_id, nil)
             |> assign(:rename_form, nil)
             |> stream_insert(:references, updated)}

          {:error, %Ecto.Changeset{} = changeset} ->
            {:noreply,
             socket
             |> assign(:rename_form, to_form(changeset, as: :reference))
             |> stream_insert(:references, reference)}

          {:error, :not_owned} ->
            {:noreply,
             socket
             |> assign(:renaming_id, nil)
             |> assign(:rename_form, nil)
             |> stream_insert(:references, reference)}
        end
    end
  end

  # -- delete (DR-30, XC-24, XC-40) -------------------------------------------------------

  def handle_event("confirm_delete", %{"id" => id}, socket) do
    id = String.to_integer(id)

    case find_reference(socket, id) do
      nil ->
        {:noreply, socket}

      reference ->
        {:noreply, socket |> assign(:confirming_id, id) |> stream_insert(:references, reference)}
    end
  end

  def handle_event("cancel_delete", _params, socket) do
    reference = find_reference(socket, socket.assigns.confirming_id)
    socket = assign(socket, :confirming_id, nil)

    socket =
      case reference do
        nil -> socket
        reference -> stream_insert(socket, :references, reference)
      end

    {:noreply, socket}
  end

  def handle_event("delete_confirmed", %{"id" => id}, socket) do
    case find_reference(socket, id) do
      nil ->
        {:noreply, assign(socket, :confirming_id, nil)}

      reference ->
        case References.delete_reference(
               socket.assigns.current_scope,
               socket.assigns.owner,
               reference
             ) do
          {:ok, deleted} ->
            {:noreply,
             socket |> assign(:confirming_id, nil) |> stream_delete(:references, deleted)}

          {:error, :not_owned} ->
            {:noreply,
             socket |> assign(:confirming_id, nil) |> stream_insert(:references, reference)}
        end
    end
  end

  # -- private -----------------------------------------------------------------------

  defp find_reference(socket, id) when is_binary(id),
    do: find_reference(socket, String.to_integer(id))

  defp find_reference(socket, id) when is_integer(id),
    do: Enum.find(socket.assigns.references, &(&1.id == id))

  defp find_reference(_socket, nil), do: nil

  defp fresh_file_form, do: to_form(%{"label" => ""}, as: :file)
  defp fresh_url_form, do: to_form(Reference.url_changeset(%Reference{}, %{}), as: :url)

  defp error_message(:unsupported_type), do: "Only PDF, PNG, JPEG or WebP files"
  defp error_message(:too_large), do: "Too large — the limit is 10 MB"
  defp error_message(:empty), do: "That file is empty"

  defp error_message(%Ecto.Changeset{} = changeset) do
    case translate_errors(changeset.errors, :label) do
      [message | _] -> "Label #{message}"
      [] -> "Could not add that file"
    end
  end

  defp error_message(_other), do: "Could not add that file"

  defp entry_error(:too_large), do: "Too large — the limit is 10 MB"
  defp entry_error(:not_accepted), do: "Only PDF, PNG, JPEG or WebP files"
  defp entry_error(:too_many_files), do: "One file at a time"
  defp entry_error(_other), do: "This file could not be uploaded"

  defp image?("image/" <> _rest), do: true
  defp image?(_content_type), do: false

  defp kind_label(%Reference{kind: :file, content_type: content_type}),
    do: Storage.type_label(content_type)

  defp kind_label(%Reference{kind: :url}), do: "Link"

  defp url_host(url) do
    case URI.new(url) do
      {:ok, %URI{host: host}} when is_binary(host) and host != "" -> host
      _ -> url
    end
  end

  defp format_size(bytes) when bytes < 1024, do: "#{bytes} B"

  defp format_size(bytes) when bytes < 1024 * 1024,
    do: "#{:erlang.float_to_binary(bytes / 1024, decimals: 1)} KB"

  defp format_size(bytes),
    do: "#{:erlang.float_to_binary(bytes / (1024 * 1024), decimals: 1)} MB"

  defp secondary_button_class do
    "inline-flex min-h-11 items-center justify-center gap-2 rounded-field px-4 text-sm font-semibold " <>
      "cursor-pointer transition-all duration-150 ease-out active:scale-[0.98] " <>
      "focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-accent focus-visible:ring-offset-2 focus-visible:ring-offset-paper " <>
      "disabled:cursor-not-allowed disabled:opacity-50 disabled:active:scale-100 " <>
      "bg-transparent text-ink border border-line-strong hover:bg-surface active:bg-line"
  end

  defp icon_button_class do
    "inline-flex size-9 items-center justify-center rounded-field text-ink-soft transition " <>
      "hover:bg-surface hover:text-ink focus-visible:outline-none focus-visible:ring-2 " <>
      "focus-visible:ring-accent focus-visible:ring-offset-2 focus-visible:ring-offset-surface-raised"
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div id={@id} class="space-y-6">
      <div class="rounded-field border border-line bg-surface p-4">
        <p class="text-sm font-semibold text-ink">Add a file</p>
        <p class="mt-0.5 text-xs text-ink-faint">PDF, PNG, JPEG or WebP, up to 10 MB.</p>

        <.form
          for={@file_form}
          id={"#{@id}-upload-form"}
          phx-change="validate_upload"
          phx-submit="save_upload"
          phx-target={@myself}
          class="mt-3 space-y-3"
        >
          <.input
            field={@file_form[:label]}
            type="text"
            id={"#{@id}-label"}
            label="Label (optional)"
            placeholder="Defaults to the file name"
          />

          <div id={"#{@id}-file-input"}>
            <.live_file_input upload={@uploads.file} />
          </div>

          <div :for={entry <- @uploads.file.entries} class="space-y-1">
            <div class="flex items-center justify-between text-sm text-ink-soft">
              <span>{entry.client_name}</span>
              <button
                type="button"
                phx-click="cancel_file_entry"
                phx-value-ref={entry.ref}
                phx-target={@myself}
                aria-label={"Remove #{entry.client_name}"}
                class="text-ink-faint hover:text-bad"
              >
                <.icon name="hero-x-mark" class="size-4" />
              </button>
            </div>
            <div class="h-1.5 w-full overflow-hidden rounded-full bg-surface">
              <div class="h-full bg-accent transition-all" style={"width: #{entry.progress}%"}></div>
            </div>
            <p :for={err <- upload_errors(@uploads.file, entry)} class="text-sm text-bad">
              {entry_error(err)}
            </p>
          </div>

          <p :for={err <- upload_errors(@uploads.file)} class="text-sm text-bad">
            {entry_error(err)}
          </p>
          <p :if={@upload_error} class="text-sm text-bad">{@upload_error}</p>

          <.button variant="primary" id={"#{@id}-upload-submit"}>Add file</.button>
        </.form>
      </div>

      <div class="rounded-field border border-line bg-surface p-4">
        <p class="text-sm font-semibold text-ink">Add a link</p>

        <.form
          for={@url_form}
          id={"#{@id}-url-form"}
          phx-change="validate_url"
          phx-submit="save_url"
          phx-target={@myself}
          class="mt-3 space-y-3"
        >
          <.input field={@url_form[:label]} type="text" id={"#{@id}-url-label"} label="Label" />
          <.input
            field={@url_form[:url]}
            type="url"
            id={"#{@id}-url"}
            label="URL"
            placeholder="https://…"
          />
          <.button variant="primary" id={"#{@id}-url-submit"}>Add link</.button>
        </.form>
      </div>

      <div id={"#{@id}-list"} phx-update="stream" class="space-y-3">
        <p id={"#{@id}-empty"} class="hidden text-sm text-ink-faint only:block">
          No references yet.
        </p>

        <div
          :for={{dom_id, reference} <- @streams.references}
          id={dom_id}
          class="rounded-field border border-line bg-surface-raised p-4"
        >
          <div class="flex items-start justify-between gap-3">
            <div class="min-w-0 flex-1">
              <div :if={@renaming_id != reference.id}>
                <a
                  :if={reference.kind == :url}
                  href={reference.url}
                  target="_blank"
                  rel="noopener noreferrer"
                  class="font-medium text-accent break-words hover:underline"
                >
                  {reference.label}
                </a>
                <p :if={reference.kind == :file} class="font-medium break-words text-ink">
                  {reference.label}
                </p>
                <p :if={reference.kind == :url} class="text-xs text-ink-faint">
                  {url_host(reference.url)}
                </p>
              </div>

              <p class="mt-0.5 text-xs text-ink-faint">
                <span>{kind_label(reference)}</span>
                <span :if={reference.kind == :file} aria-hidden="true">&middot;</span>
                <span :if={reference.kind == :file}>{format_size(reference.byte_size)}</span>
                <span aria-hidden="true">&middot;</span>
                <span>Added {Format.datetime(reference.inserted_at, @time_zone)}</span>
              </p>

              <div :if={reference.kind == :file} class="mt-2 flex flex-wrap items-center gap-3">
                <a
                  :if={image?(reference.content_type)}
                  href={~p"/references/#{reference.id}/file"}
                  target="_blank"
                  rel="noopener noreferrer"
                >
                  <img
                    src={~p"/references/#{reference.id}/file"}
                    loading="lazy"
                    alt={reference.label}
                    class="h-20 w-20 rounded-field border border-line object-cover"
                  />
                </a>
                <a
                  :if={reference.content_type == "application/pdf"}
                  href={~p"/references/#{reference.id}/file"}
                  target="_blank"
                  rel="noopener noreferrer"
                  class="inline-flex items-center gap-1 text-sm font-medium text-accent hover:underline"
                >
                  <.icon name="hero-document" class="size-4" /> Open
                </a>
                <a
                  href={~p"/references/#{reference.id}/download"}
                  class="inline-flex items-center gap-1 text-sm font-medium text-accent hover:underline"
                >
                  <.icon name="hero-arrow-down-tray" class="size-4" /> Download
                </a>
              </div>

              <.form
                :if={@renaming_id == reference.id}
                for={@rename_form}
                id={"#{@id}-ref-#{reference.id}-rename"}
                phx-submit="save_rename"
                phx-target={@myself}
                class="mt-3 flex flex-wrap items-end gap-2"
              >
                <.input
                  field={@rename_form[:label]}
                  type="text"
                  label="Label"
                  id={"#{@id}-ref-#{reference.id}-rename-label"}
                  phx-blur={JS.dispatch("submit", to: "##{@id}-ref-#{reference.id}-rename")}
                />
                <.input
                  :if={reference.kind == :url}
                  field={@rename_form[:url]}
                  type="url"
                  label="URL"
                  id={"#{@id}-ref-#{reference.id}-rename-url"}
                  phx-blur={JS.dispatch("submit", to: "##{@id}-ref-#{reference.id}-rename")}
                />
                <button
                  type="button"
                  phx-click="cancel_rename"
                  phx-target={@myself}
                  class={secondary_button_class()}
                >
                  Cancel
                </button>
              </.form>
            </div>

            <div class="flex shrink-0 items-center gap-1">
              <button
                :if={@renaming_id != reference.id}
                type="button"
                id={"#{@id}-ref-#{reference.id}-rename"}
                phx-click="start_rename"
                phx-value-id={reference.id}
                phx-target={@myself}
                aria-label={"Rename '#{reference.label}'"}
                class={icon_button_class()}
              >
                <.icon name="hero-pencil-square" class="size-5" />
              </button>
              <button
                type="button"
                id={"#{@id}-ref-#{reference.id}-delete"}
                phx-click="confirm_delete"
                phx-value-id={reference.id}
                phx-target={@myself}
                aria-label={"Delete '#{reference.label}'"}
                class={icon_button_class()}
              >
                <.icon name="hero-trash" class="size-5" />
              </button>
            </div>
          </div>

          <.destructive_confirm
            :if={@confirming_id == reference.id}
            id={"#{@id}-ref-#{reference.id}-delete-confirm"}
            title={"Remove '#{reference.label}'?"}
            body="The file is removed from storage too. This cannot be undone."
            confirm="delete_confirmed"
            confirm_value={reference.id}
            cancel="cancel_delete"
            target={@myself}
          />
        </div>
      </div>
    </div>
    """
  end
end
