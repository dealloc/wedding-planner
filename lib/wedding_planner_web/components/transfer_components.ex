defmodule WeddingPlannerWeb.Components.TransferComponents do
  @moduledoc """
  Rendering for the Settings "Transfer data" section (`WeddingPlannerWeb.Live.SettingsLive`,
  task 101; `DR-93`, `DR-97`, `XC-40`): the preview/confirm panel, the done and refused
  panels, and the safety-copies list. Pure function components — every branch of the
  state machine (`:checking | :preview | :importing | :done | :refused`) is decided by the
  host LiveView; these only render the flat data (a `WeddingPlanner.Transfer.Preview.t()`,
  `Result.t()` or `Refusal.t()`) they are handed.

  ## Compact counts (`NFR-31`)

  `transfer_counts/1` is one tight two-number row per kind, not cards: rows where the file
  and the current count differ carry emphasis (`font-semibold`); a kind that is empty on
  both sides collapses out of the list into one quiet trailing line ("Also empty in both:
  …") rather than a zero/zero row, so a fresh installation's preview doesn't scroll through
  fifteen empty lines.
  """

  use WeddingPlannerWeb, :html

  alias WeddingPlannerWeb.Format

  # -- preview (checking/importing panel) --------------------------------------------------

  attr :id, :string, required: true
  attr :preview, :map, required: true
  attr :importing?, :boolean, default: false
  attr :time_zone, :string, default: nil

  @doc """
  The preview/confirm panel (`XC-40`'s confirmation, `DR-93` (5)). Renders identically
  while `:importing?` is true except the confirm button is disabled and reads
  "Importing…", and the `aria-live="polite"` status line appears — the host keeps this
  component mounted through both states (`:preview` and `:importing`) so nothing else in
  the panel jumps around.
  """
  def transfer_preview(assigns) do
    ~H"""
    <div id={@id} class="mt-4 space-y-4 rounded-field border border-line bg-surface p-4">
      <p class="text-sm text-ink-soft">
        Exported
        <span class="font-medium text-ink">{Format.datetime(@preview.exported_at, @time_zone)}</span>
        from <span class="font-medium text-ink">{@preview.source_host}</span>
        · data version <span class="tabular-nums">{@preview.schema_version}</span>
      </p>

      <.transfer_counts id="transfer-counts" counts={@preview.counts} />

      <p class="text-sm text-ink-soft">{files_line(@preview.files)}</p>

      <p :if={@preview.missing_files > 0} class="text-sm text-warn">
        {missing_files_line(@preview.missing_files)}
      </p>

      <div :if={@preview.users != []} id="transfer-users" class="space-y-1">
        <p
          :for={{user, index} <- Enum.with_index(@preview.users)}
          id={"transfer-user-#{index}"}
          class="text-sm text-ink-soft"
        >
          {user_line(user)}
        </p>
      </div>

      <div class="space-y-1 rounded-field border border-bad/30 bg-bad-soft p-3">
        <p id="transfer-warning" class="text-sm font-semibold text-bad">
          This replaces all data in this app.
        </p>
        <p class="text-xs text-ink-soft">A safety copy of the current data is saved first.</p>
      </div>

      <div class="flex flex-wrap items-center gap-2">
        <.button
          id="transfer-cancel"
          phx-click="cancel_import"
          disabled={@importing?}
          class="phx-click-loading:opacity-60 inline-flex min-h-11 items-center justify-center gap-2 rounded-field border border-line-strong bg-transparent px-4 text-sm font-semibold text-ink transition-all duration-150 ease-out hover:bg-surface active:scale-[0.98] active:bg-line disabled:cursor-not-allowed disabled:opacity-50"
        >
          Cancel
        </.button>
        <.button
          variant="destructive"
          id="transfer-confirm"
          phx-click={JS.push("confirm_import", loading: "#transfer-panel")}
          phx-disable-with="Importing…"
          disabled={@importing?}
        >
          {if @importing?, do: "Importing…", else: "Replace all data"}
        </.button>
      </div>

      <p
        :if={@importing?}
        id="transfer-status"
        aria-live="polite"
        class="flex items-center gap-1.5 text-sm text-ink-soft"
      >
        <span
          class="size-3 shrink-0 animate-spin rounded-full border-2 border-ink-faint border-t-transparent"
          aria-hidden="true"
        ></span>
        Importing…
      </p>
    </div>
    """
  end

  attr :id, :string, required: true
  attr :counts, :list, required: true

  defp transfer_counts(assigns) do
    # Only the kinds that change get a row; the rest collapse into one line each (compact).
    {nonempty, empty} =
      Enum.split_with(assigns.counts, fn count -> count.in_file != 0 or count.here_now != 0 end)

    {shown, unchanged} =
      Enum.split_with(nonempty, fn count -> count.in_file != count.here_now end)

    assigns = assign(assigns, shown: shown, unchanged: unchanged, empty: empty)

    ~H"""
    <div id={@id} class="divide-y divide-line text-sm">
      <div
        :for={count <- @shown}
        id={"transfer-count-#{count.key}"}
        class="flex items-center justify-between gap-3 py-1 font-semibold text-ink"
      >
        <span>{count.label}</span>
        <span class="tabular-nums text-ink-soft">
          {count.in_file} in the file · {count.here_now} here now
        </span>
      </div>
      <p :if={@unchanged != []} id="transfer-counts-unchanged" class="pt-1 text-xs text-ink-soft">
        Unchanged: {Enum.map_join(@unchanged, " · ", &"#{&1.label} #{&1.in_file}")}
      </p>
      <p :if={@empty != []} id="transfer-counts-empty" class="pt-1 text-xs text-ink-faint">
        Also empty in both: {Enum.map_join(@empty, ", ", & &1.label)}
      </p>
    </div>
    """
  end

  defp files_line(%{in_file: in_file, in_file_bytes: bytes, here_now: here_now}) do
    "#{pluralize(in_file, "file", "files")} (#{format_size(bytes)}) in the file · " <>
      "#{here_now} here now"
  end

  defp missing_files_line(1) do
    "1 file was missing where this was exported; that reference stays without a file."
  end

  defp missing_files_line(count) when count > 1 do
    "#{count} files were missing where this was exported; those references stay without a file."
  end

  defp user_line(%{matched?: true, source_name: source, target_name: target}) do
    "#{source} → #{target}"
  end

  defp user_line(%{matched?: false, source_name: source, target_name: target}) do
    "#{source} → you (#{target}): no user with that name here"
  end

  # -- done ----------------------------------------------------------------------------------

  attr :id, :string, required: true
  attr :result, :map, required: true
  attr :time_zone, :string, default: nil

  @doc "The success panel: a one-line summary and the safety-copy download (`DR-93` (5))."
  def transfer_done(assigns) do
    ~H"""
    <div id={@id} class="mt-4 space-y-3 rounded-field border border-line bg-surface p-4">
      <p class="text-sm font-semibold text-ink">
        Imported: exported {Format.datetime(@result.exported_at, @time_zone)} from {@result.source_host}.
      </p>

      <p class="text-sm text-ink">Everything in this app now matches the file.</p>
      <p id="transfer-done-counts" class="text-xs text-ink-soft">
        {@result.counts
        |> Enum.reject(&(&1.imported == 0))
        |> Enum.map_join(" · ", &"#{&1.label} #{&1.imported}")}
        <span :if={@result.files_written + @result.files_removed > 0}>
          · Files: {@result.files_written} written, {@result.files_removed} removed
        </span>
      </p>

      <p>
        <a
          id="transfer-safety-copy-link"
          href={~p"/transfer/safety-copies/#{@result.safety_copy}"}
          download
          class="inline-flex items-center gap-1 text-sm font-medium text-accent hover:underline"
        >
          <.icon name="hero-arrow-down-tray" class="size-4" /> Download the safety copy
        </a>
      </p>

      <p class="text-xs text-ink-faint">To undo, import the safety copy.</p>
    </div>
    """
  end

  # -- refused ---------------------------------------------------------------------------------

  attr :id, :string, required: true
  attr :refusal, :map, required: true

  @doc "The refusal panel: the message verbatim, nothing else changed (`DR-93` (4))."
  def transfer_refused(assigns) do
    ~H"""
    <div id={@id} class="mt-4 space-y-3 rounded-field border border-bad/30 bg-bad-soft p-4">
      <p class="text-sm font-semibold text-bad">{@refusal.message}</p>
      <.button id="transfer-choose-another" phx-click="choose_another">
        Choose another file
      </.button>
    </div>
    """
  end

  # -- safety copies -----------------------------------------------------------------------

  attr :id, :string, required: true
  attr :copies, :list, required: true
  attr :time_zone, :string, default: nil

  attr :confirming, :string,
    default: nil,
    doc: "the name of the copy awaiting delete confirmation"

  @doc "The safety copies (`DR-97`), newest first, hidden when there are none; each can be deleted."
  def transfer_safety_copies(assigns) do
    ~H"""
    <div :if={@copies != []} id={@id} class="mt-4">
      <h3 class="text-xs font-semibold text-ink-soft">Safety copies</h3>
      <ul class="mt-1 space-y-1">
        <li :for={{copy, index} <- Enum.with_index(@copies)} class="text-sm">
          <a
            id={"transfer-safety-copy-#{index}"}
            href={~p"/transfer/safety-copies/#{copy.name}"}
            download
            class="inline-flex items-center gap-1 text-accent hover:underline"
          >
            <.icon name="hero-arrow-down-tray" class="size-4" />
            {Format.datetime(copy.saved_at, @time_zone)}
          </a>
          <span class="text-xs text-ink-faint">({format_size(copy.byte_size)})</span>
          <button
            :if={@confirming != copy.name}
            type="button"
            id={"transfer-safety-copy-#{index}-delete"}
            phx-click="confirm_delete_safety_copy"
            phx-value-name={copy.name}
            class="ml-2 text-xs font-medium text-ink-soft hover:text-bad hover:underline"
          >
            Delete
          </button>
          <.destructive_confirm
            :if={@confirming == copy.name}
            id={"transfer-safety-copy-#{index}-delete-confirm"}
            title="Delete this safety copy?"
            body="You will no longer be able to undo the import it was saved for. This cannot be undone."
            confirm="delete_safety_copy"
            confirm_value={copy.name}
            cancel="cancel_delete_safety_copy"
          />
        </li>
      </ul>
    </div>
    """
  end

  # -- helpers -------------------------------------------------------------------------------

  defp pluralize(1, singular, _plural), do: "1 #{singular}"
  defp pluralize(count, _singular, plural), do: "#{count} #{plural}"

  defp format_size(bytes) when bytes < 1024, do: "#{bytes} B"

  defp format_size(bytes) when bytes < 1024 * 1024,
    do: "#{:erlang.float_to_binary(bytes / 1024, decimals: 1)} KB"

  defp format_size(bytes),
    do: "#{:erlang.float_to_binary(bytes / (1024 * 1024), decimals: 1)} MB"
end
