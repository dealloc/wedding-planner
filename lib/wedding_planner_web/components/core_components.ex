defmodule WeddingPlannerWeb.CoreComponents do
  @moduledoc """
  Provides core UI components.

  At first glance, this module may seem daunting, but its goal is to provide
  core building blocks for your application, such as tables, forms, and
  inputs. The components consist mostly of markup and are well-documented
  with doc strings and declarative assigns. You may customize and style
  them in any way you want, based on your application growth and needs.

  The foundation for styling is Tailwind CSS, a utility-first CSS framework.
  Components here are hand-written Tailwind, styled from the design tokens
  declared in `assets/css/app.css` (see the `@theme` block) rather than a
  component kit — this app has no daisyUI. `--radius-field` is used for
  buttons, inputs and cards; `--radius-chip` is reserved for the small
  chip/badge-style components introduced later and is intentionally not used
  here. Here are useful references:

    * [Tailwind CSS](https://tailwindcss.com) - the foundational framework
      we build on. You will use it for layout, sizing, flexbox, grid, and
      spacing.

    * [Heroicons](https://heroicons.com) - see `icon/1` for usage.

    * [Phoenix.Component](https://phoenix-live-view.hexdocs.pm/Phoenix.Component.html) -
      the component system used by Phoenix. Some components, such as `<.link>`
      and `<.form>`, are defined there.

  """
  use Phoenix.Component

  alias Phoenix.LiveView.JS

  @doc """
  Renders flash notices.

  Flash kinds map to a fixed color per `.claude/ui-decisions.md` §2: `:info`
  uses the soft accent tint (accent-adjacent chrome), `:error` uses the soft
  "bad" tint. This is the sanctioned exception to "accent is never used for
  status" — that rule is about domain status (want tier, gap severity,
  invitation state), not a transient flash.

  ## Examples

      <.flash kind={:info} flash={@flash} />
      <.flash
        id="welcome-back"
        kind={:info}
        phx-mounted={show("#welcome-back") |> JS.remove_attribute("hidden")}
        hidden
      >
        Welcome Back!
      </.flash>
  """
  attr :id, :string, doc: "the optional id of flash container"
  attr :flash, :map, default: %{}, doc: "the map of flash messages to display"
  attr :title, :string, default: nil
  attr :kind, :atom, values: [:info, :error], doc: "used for styling and flash lookup"
  attr :rest, :global, doc: "the arbitrary HTML attributes to add to the flash container"

  slot :inner_block, doc: "the optional inner block that renders the flash message"

  def flash(assigns) do
    assigns = assign_new(assigns, :id, fn -> "flash-#{assigns.kind}" end)

    ~H"""
    <div
      :if={msg = render_slot(@inner_block) || Phoenix.Flash.get(@flash, @kind)}
      id={@id}
      phx-click={JS.push("lv:clear-flash", value: %{key: @kind}) |> hide("##{@id}")}
      role="alert"
      class="fixed top-4 right-4 z-50 w-80 sm:w-96 max-w-[calc(100vw-2rem)]"
      {@rest}
    >
      <div class={[
        "flex items-start gap-3 rounded-field p-4 shadow-lg ring-1 text-sm text-wrap",
        @kind == :info && "bg-accent-soft ring-accent/10",
        @kind == :error && "bg-bad-soft ring-bad/10"
      ]}>
        <.icon
          :if={@kind == :info}
          name="hero-information-circle"
          class="size-5 shrink-0 text-accent"
        />
        <.icon
          :if={@kind == :error}
          name="hero-exclamation-circle"
          class="size-5 shrink-0 text-bad"
        />
        <div class="min-w-0 flex-1 pt-0.5">
          <p :if={@title} class="font-semibold text-ink">{@title}</p>
          <p class="text-ink">{msg}</p>
        </div>
        <button
          type="button"
          class="group -m-2 shrink-0 self-start rounded-field p-2 cursor-pointer transition hover:bg-ink/5 focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-accent"
          aria-label="close"
        >
          <.icon name="hero-x-mark" class="size-5 text-ink-faint transition group-hover:text-ink" />
        </button>
      </div>
    </div>
    """
  end

  @doc """
  Renders a button with navigation support.

  Three variants only, per the locked design record: `primary` (solid
  accent, the main call to action), `secondary` (outline, transparent fill,
  the default), and `destructive` (solid "bad" tone, for irreversible
  actions). There is no ghost variant — this is a two-person private app
  with no marketing chrome.

  ## Examples

      <.button>Cancel</.button>
      <.button variant="primary" phx-click="go">Send!</.button>
      <.button variant="destructive" phx-click="delete" data-confirm="Are you sure?">Delete</.button>
      <.button navigate={~p"/"}>Home</.button>
  """
  attr :rest, :global, include: ~w(href navigate patch method download name value disabled form)
  attr :class, :any, doc: "overrides the default variant classes entirely when set"
  attr :variant, :string, default: "secondary", values: ~w(primary secondary destructive)
  slot :inner_block, required: true

  def button(%{rest: rest} = assigns) do
    variants = %{
      "primary" => "bg-accent text-white shadow-sm hover:opacity-90 active:opacity-95",
      "secondary" =>
        "bg-transparent text-ink border border-line-strong hover:bg-surface active:bg-line",
      "destructive" => "bg-bad text-white shadow-sm hover:opacity-90 active:opacity-95"
    }

    assigns =
      assign(
        assigns,
        :class,
        assigns[:class] ||
          [
            "inline-flex min-h-11 items-center justify-center gap-2 rounded-field px-4 text-sm font-semibold",
            "cursor-pointer transition-all duration-150 ease-out active:scale-[0.98]",
            "focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-accent focus-visible:ring-offset-2 focus-visible:ring-offset-paper",
            "disabled:cursor-not-allowed disabled:opacity-50 disabled:active:scale-100",
            Map.fetch!(variants, assigns[:variant])
          ]
      )

    if rest[:href] || rest[:navigate] || rest[:patch] do
      ~H"""
      <.link class={@class} {@rest}>
        {render_slot(@inner_block)}
      </.link>
      """
    else
      ~H"""
      <button class={@class} {@rest}>
        {render_slot(@inner_block)}
      </button>
      """
    end
  end

  @doc """
  Renders the destructive-confirmation panel required by `XC-40`: every destructive
  action MUST require confirmation and state what else is affected (task 05's brief
  named this component but never built it — task 22, the events exemplar slice, built
  it here so every later slice can reuse it rather than each inventing its own).

  This is a **plain, stateless function component** — same contract as
  `WeddingPlannerWeb.ActivityComponents.entity_history/1`. It renders unconditionally
  wherever it is placed; the host LiveView decides *when* it exists in the DOM,
  typically by keeping an assign for "which record is pending deletion" and wrapping
  the call site in `:if={@confirming_id == record.id}` — no client-side open/close
  state lives inside this component, which keeps it trivially testable by DOM id
  (`has_element?/2`/`refute has_element?/2` for presence, no JS execution needed).

  No form is involved: `:confirm` and `:cancel` are plain `phx-click` event names the
  host's `handle_event/3` implements — `:confirm_value` (typically the record's id) is
  forwarded as `phx-value-id` on the confirm button only, so the handler knows which
  record was confirmed without the cancel button carrying a stale value.

  ## Attrs

    * `:id` (required) — unique DOM id; the title, affected-references list, cancel and
      confirm buttons are namespaced under it (`"\#{id}-title"`, `"\#{id}-affected"`,
      `"\#{id}-cancel"`, `"\#{id}-confirm"`).
    * `:title` (required) — the question, e.g. `"Delete 'Dinner'?"`.
    * `:body` — an optional extra sentence under the title (e.g. "This cannot be
      undone.").
    * `:affected` (default `[]`) — `[%{label: String.t(), count: non_neg_integer()}]`,
      one row per reference *type* that would be affected, e.g.
      `[%{label: "2 invitations", count: 2}, %{label: "1 offer line", count: 1}]`.
      Deliberately a list of maps, not a fixed set of assigns, so a later slice adding a
      new reference type (invitations, offer lines, tasks — see `WeddingPlanner.Events`'
      `affected_references/1` for the first caller) is purely additive: build a longer
      list, this component does not change. `[]` renders a reassuring
      "Nothing else references this yet." line instead of an empty list, so absence of
      danger is stated, not implied by a blank space.
    * `:confirm` (required) — the `phx-click` event name for the confirm button.
    * `:confirm_value` — forwarded as `phx-value-id` on the confirm button.
    * `:cancel` (required) — the `phx-click` event name for the cancel button.
    * `:confirm_label` (default `"Delete"`) — the confirm button's text, for a
      destructive action that isn't literally a delete.
    * `:target` (default `nil`) — forwarded as `phx-target` on both the cancel and
      confirm buttons, so a host embedding this inside a `LiveComponent` (e.g.
      `WeddingPlannerWeb.ReferencesComponent`, `DR-31`) can target its own `@myself`
      instead of the events silently falling through to the parent LiveView, which has
      no matching `handle_event/3`. `nil` renders no `phx-target`, so every existing
      call site (which relies on the confirm/cancel events reaching the host LiveView
      directly) keeps working unchanged.

  ## Examples

      <.destructive_confirm
        :if={@confirming_id == event.id}
        id={"event-\#{event.id}-delete-confirm"}
        title={"Delete '\#{event.name}'?"}
        body="This cannot be undone."
        affected={Events.affected_references(event)}
        confirm="delete_confirmed"
        confirm_value={event.id}
        cancel="cancel_delete"
      />

      <.destructive_confirm
        :if={@confirming_id == reference.id}
        id={"refs-ref-\#{reference.id}-delete-confirm"}
        title={"Remove '\#{reference.label}'?"}
        confirm="delete_confirmed"
        confirm_value={reference.id}
        cancel="cancel_delete"
        target={@myself}
      />
  """
  attr :id, :string, required: true
  attr :title, :string, required: true
  attr :body, :string, default: nil
  attr :affected, :list, default: [], doc: "[%{label: String.t(), count: non_neg_integer()}]"
  attr :confirm, :string, required: true, doc: "phx-click event name for the confirm button"
  attr :confirm_value, :any, default: nil
  attr :cancel, :string, required: true, doc: "phx-click event name for the cancel button"
  attr :confirm_label, :string, default: "Delete"
  attr :target, :any, default: nil, doc: "forwarded as phx-target on both buttons"

  def destructive_confirm(assigns) do
    ~H"""
    <div
      id={@id}
      role="alertdialog"
      aria-labelledby={"#{@id}-title"}
      class="rounded-field border border-bad/30 bg-bad-soft p-4"
    >
      <p id={"#{@id}-title"} class="text-sm font-semibold text-ink">{@title}</p>
      <p :if={@body} class="mt-1 text-sm text-ink-soft">{@body}</p>

      <div id={"#{@id}-affected"} class="mt-3 text-sm">
        <p :if={@affected == []} class="text-ink-faint">Nothing else references this yet.</p>
        <ul :if={@affected != []} class="list-disc space-y-0.5 pl-5 text-ink">
          <li :for={ref <- @affected}>{ref.label}</li>
        </ul>
      </div>

      <div class="mt-4 flex flex-wrap gap-2">
        <.button id={"#{@id}-cancel"} phx-click={@cancel} phx-target={@target}>
          Cancel
        </.button>
        <.button
          variant="destructive"
          id={"#{@id}-confirm"}
          phx-click={@confirm}
          phx-value-id={@confirm_value}
          phx-target={@target}
        >
          {@confirm_label}
        </.button>
      </div>
    </div>
    """
  end

  @doc """
  Renders an input with label and error messages.

  A `Phoenix.HTML.FormField` may be passed as argument,
  which is used to retrieve the input name, id, and values.
  Otherwise all attributes may be passed explicitly.

  Text, select, textarea and checkbox all share one border and focus-ring
  treatment; the error state swaps border and ring to `--color-bad` instead
  of introducing a separate error component.

  ## Types

  This function accepts all HTML input types, considering that:

    * You may also set `type="select"` to render a `<select>` tag

    * `type="checkbox"` is used exclusively to render boolean values

    * For live file uploads, see `Phoenix.Component.live_file_input/1`

  See https://developer.mozilla.org/en-US/docs/Web/HTML/Element/input
  for more information. Unsupported types, such as radio, are best
  written directly in your templates.

  ## Examples

  ```heex
  <.input field={@form[:email]} type="email" />
  <.input name="my-input" errors={["oh no!"]} />
  ```

  ## Select type

  When using `type="select"`, you must pass the `options` and optionally
  a `value` to mark which option should be preselected.

  ```heex
  <.input field={@form[:user_type]} type="select" options={["Admin": "admin", "User": "user"]} />
  ```

  For more information on what kind of data can be passed to `options` see
  [`options_for_select`](https://phoenix-html.hexdocs.pm/Phoenix.HTML.Form.html#options_for_select/2).
  """
  attr :id, :any, default: nil
  attr :name, :any
  attr :label, :string, default: nil
  attr :value, :any

  attr :type, :string,
    default: "text",
    values: ~w(checkbox color date datetime-local email file month number password
               search select tel text textarea time url week hidden)

  attr :field, Phoenix.HTML.FormField,
    doc: "a form field struct retrieved from the form, for example: @form[:email]"

  attr :errors, :list, default: []
  attr :checked, :boolean, doc: "the checked flag for checkbox inputs"
  attr :prompt, :string, default: nil, doc: "the prompt for select inputs"
  attr :options, :list, doc: "the options to pass to Phoenix.HTML.Form.options_for_select/2"
  attr :multiple, :boolean, default: false, doc: "the multiple flag for select inputs"
  attr :class, :any, default: nil, doc: "the input class to use over defaults"
  attr :error_class, :any, default: nil, doc: "the input error class to use over defaults"

  attr :rest, :global,
    include: ~w(accept autocomplete capture cols disabled form list max maxlength min minlength
                multiple pattern placeholder readonly required rows size step)

  def input(%{field: %Phoenix.HTML.FormField{} = field} = assigns) do
    errors = if Phoenix.Component.used_input?(field), do: field.errors, else: []

    assigns
    |> assign(field: nil, id: assigns.id || field.id)
    |> assign(:errors, Enum.map(errors, &translate_error(&1)))
    |> assign_new(:name, fn -> if assigns.multiple, do: field.name <> "[]", else: field.name end)
    |> assign_new(:value, fn -> field.value end)
    |> input()
  end

  def input(%{type: "hidden"} = assigns) do
    ~H"""
    <input type="hidden" id={@id} name={@name} value={@value} {@rest} />
    """
  end

  def input(%{type: "checkbox"} = assigns) do
    assigns =
      assign_new(assigns, :checked, fn ->
        Phoenix.HTML.Form.normalize_value("checkbox", assigns[:value])
      end)

    ~H"""
    <div>
      <label for={@id} class="flex min-h-11 cursor-pointer items-center gap-2">
        <input
          type="hidden"
          name={@name}
          value="false"
          disabled={@rest[:disabled]}
          form={@rest[:form]}
        />
        <input
          type="checkbox"
          id={@id}
          name={@name}
          value="true"
          checked={@checked}
          class={
            @class ||
              "size-5 rounded border-line-strong accent-accent transition focus:outline-none focus:ring-2 focus:ring-accent focus:ring-offset-1 focus:ring-offset-paper"
          }
          {@rest}
        />
        <span class="text-sm text-ink select-none">{@label}</span>
      </label>
      <.error :for={msg <- @errors}>{msg}</.error>
    </div>
    """
  end

  def input(%{type: "select"} = assigns) do
    ~H"""
    <div>
      <label for={@id} class="block">
        <span :if={@label} class="mb-1 block text-sm font-medium text-ink-soft">{@label}</span>
        <select
          id={@id}
          name={@name}
          class={select_class(@class, @errors, @error_class)}
          multiple={@multiple}
          {@rest}
        >
          <option :if={@prompt} value="">{@prompt}</option>
          {Phoenix.HTML.Form.options_for_select(@options, @value)}
        </select>
      </label>
      <.error :for={msg <- @errors}>{msg}</.error>
    </div>
    """
  end

  def input(%{type: "textarea"} = assigns) do
    ~H"""
    <div>
      <label for={@id} class="block">
        <span :if={@label} class="mb-1 block text-sm font-medium text-ink-soft">{@label}</span>
        <textarea
          id={@id}
          name={@name}
          class={input_class(@class, @errors, @error_class, false)}
          {@rest}
        >{Phoenix.HTML.Form.normalize_value("textarea", @value)}</textarea>
      </label>
      <.error :for={msg <- @errors}>{msg}</.error>
    </div>
    """
  end

  # All other inputs text, datetime-local, url, password, etc. are handled here...
  def input(assigns) do
    ~H"""
    <div>
      <label for={@id} class="block">
        <span :if={@label} class="mb-1 block text-sm font-medium text-ink-soft">{@label}</span>
        <input
          type={@type}
          name={@name}
          id={@id}
          value={Phoenix.HTML.Form.normalize_value(@type, @value)}
          class={input_class(@class, @errors, @error_class, true)}
          {@rest}
        />
      </label>
      <.error :for={msg <- @errors}>{msg}</.error>
    </div>
    """
  end

  # Shared border/focus-ring treatment for text-like inputs and selects. The
  # error state swaps border+ring to --color-bad rather than introducing a
  # separate error component (locked design decision, .claude/ui-decisions.md §2).
  defp input_class(override, errors, error_override, tap_target?) do
    override ||
      [
        "block w-full rounded-field border bg-surface-raised px-3 py-2 text-sm text-ink",
        "placeholder:text-ink-faint transition focus:outline-none focus:ring-2 focus:ring-offset-1 focus:ring-offset-surface-raised",
        tap_target? && "min-h-11",
        if(errors == [],
          do: "border-line-strong focus:border-accent focus:ring-accent",
          else: error_override || "border-bad focus:border-bad focus:ring-bad"
        )
      ]
  end

  defp select_class(override, errors, error_override),
    do: input_class(override, errors, error_override, true)

  # Helper used by inputs to generate form errors
  defp error(assigns) do
    ~H"""
    <p class="mt-1.5 flex items-center gap-2 text-sm text-bad">
      <.icon name="hero-exclamation-circle" class="size-5 shrink-0" />
      {render_slot(@inner_block)}
    </p>
    """
  end

  @doc """
  Renders a header with title.
  """
  slot :inner_block, required: true
  slot :subtitle
  slot :actions

  def header(assigns) do
    ~H"""
    <header class={[
      @actions != [] && "flex flex-wrap items-center justify-between gap-x-6 gap-y-3",
      "pb-4"
    ]}>
      <div>
        <h1 class="text-lg font-semibold leading-8 text-ink">
          {render_slot(@inner_block)}
        </h1>
        <p :if={@subtitle != []} class="text-sm text-ink-soft">
          {render_slot(@subtitle)}
        </p>
      </div>
      <%!-- Actions wrap onto more lines rather than widening the page at 390px (NFR-31). --%>
      <div :if={@actions != []} class="flex flex-wrap items-center gap-2">
        {render_slot(@actions)}
      </div>
    </header>
    """
  end

  @doc """
  Renders a table with generic styling: hairline row dividers plus faint
  zebra striping via `--color-surface`. Wrapped in a horizontally scrolling
  container so a wide table degrades gracefully on a phone (`NFR-31`)
  instead of overflowing the page.

  ## Examples

      <.table id="users" rows={@users}>
        <:col :let={user} label="id">{user.id}</:col>
        <:col :let={user} label="username">{user.username}</:col>
      </.table>
  """
  attr :id, :string, required: true
  attr :rows, :list, required: true
  attr :row_id, :any, default: nil, doc: "the function for generating the row id"
  attr :row_click, :any, default: nil, doc: "the function for handling phx-click on each row"

  attr :row_item, :any,
    default: &Function.identity/1,
    doc: "the function for mapping each row before calling the :col and :action slots"

  slot :col, required: true do
    attr :label, :string
  end

  slot :action, doc: "the slot for showing user actions in the last table column"

  def table(assigns) do
    assigns =
      with %{rows: %Phoenix.LiveView.LiveStream{}} <- assigns do
        assign(assigns, row_id: assigns.row_id || fn {id, _item} -> id end)
      end

    ~H"""
    <div class="overflow-x-auto">
      <table class="w-full min-w-full border-collapse text-left text-sm">
        <thead>
          <tr class="border-b border-line-strong">
            <th :for={col <- @col} class="py-2 pr-4 font-semibold whitespace-nowrap text-ink-soft">
              {col[:label]}
            </th>
            <th :if={@action != []} class="py-2 pr-4">
              <span class="sr-only">Actions</span>
            </th>
          </tr>
        </thead>
        <tbody id={@id} phx-update={is_struct(@rows, Phoenix.LiveView.LiveStream) && "stream"}>
          <tr
            :for={row <- @rows}
            id={@row_id && @row_id.(row)}
            class="border-b border-line odd:bg-surface"
          >
            <td
              :for={col <- @col}
              phx-click={@row_click && @row_click.(row)}
              class={["py-2 pr-4 text-ink", @row_click && "hover:cursor-pointer"]}
            >
              {render_slot(col, @row_item.(row))}
            </td>
            <td :if={@action != []} class="w-0 py-2 pr-4 font-semibold whitespace-nowrap">
              <div class="flex gap-4">
                <%= for action <- @action do %>
                  {render_slot(action, @row_item.(row))}
                <% end %>
              </div>
            </td>
          </tr>
        </tbody>
      </table>
    </div>
    """
  end

  @doc """
  Renders a data list.

  ## Examples

      <.list>
        <:item title="Title">{@post.title}</:item>
        <:item title="Views">{@post.views}</:item>
      </.list>
  """
  slot :item, required: true do
    attr :title, :string, required: true
  end

  def list(assigns) do
    ~H"""
    <ul class="divide-y divide-line">
      <li :for={item <- @item} class="py-2">
        <div class="font-bold text-ink">{item.title}</div>
        <div class="text-ink-soft">{render_slot(item)}</div>
      </li>
    </ul>
    """
  end

  @doc """
  Renders a [Heroicon](https://heroicons.com).

  Heroicons come in three styles – outline, solid, and mini.
  By default, the outline style is used, but solid and mini may
  be applied by using the `-solid` and `-mini` suffix.

  You can customize the size and colors of the icons by setting
  width, height, and background color classes.

  Icons are extracted from the `deps/heroicons` directory and bundled within
  your compiled app.css by the plugin in `assets/vendor/heroicons.js`.

  ## Examples

      <.icon name="hero-x-mark" />
      <.icon name="hero-arrow-path" class="ml-1 size-3 motion-safe:animate-spin" />
  """
  attr :name, :string, required: true
  attr :class, :any, default: "size-4"

  def icon(%{name: "hero-" <> _} = assigns) do
    ~H"""
    <span class={[@name, @class]} />
    """
  end

  ## JS Commands

  def show(js \\ %JS{}, selector) do
    JS.show(js,
      to: selector,
      time: 300,
      transition:
        {"transition-all ease-out duration-300",
         "opacity-0 translate-y-4 sm:translate-y-0 sm:scale-95",
         "opacity-100 translate-y-0 sm:scale-100"}
    )
  end

  def hide(js \\ %JS{}, selector) do
    JS.hide(js,
      to: selector,
      time: 200,
      transition:
        {"transition-all ease-in duration-200", "opacity-100 translate-y-0 sm:scale-100",
         "opacity-0 translate-y-4 sm:translate-y-0 sm:scale-95"}
    )
  end

  @doc """
  Translates an error message using gettext.
  """
  def translate_error({msg, opts}) do
    # You can make use of gettext to translate error messages by
    # uncommenting and adjusting the following code:

    # if count = opts[:count] do
    #   Gettext.dngettext(WeddingPlannerWeb.Gettext, "errors", msg, msg, count, opts)
    # else
    #   Gettext.dgettext(WeddingPlannerWeb.Gettext, "errors", msg, opts)
    # end

    Enum.reduce(opts, msg, fn {key, value}, acc ->
      String.replace(acc, "%{#{key}}", fn _ -> to_string(value) end)
    end)
  end

  @doc """
  Translates the errors for a field from a keyword list of errors.
  """
  def translate_errors(errors, field) when is_list(errors) do
    for {^field, {msg, opts}} <- errors, do: translate_error({msg, opts})
  end
end
