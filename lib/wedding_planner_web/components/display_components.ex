defmodule WeddingPlannerWeb.DisplayComponents do
  @moduledoc """
  The five recurring display idioms used on nearly every screen in this app: the
  formula-expansion disclosure, the min–max range, the headcount preset selector, the
  gap-severity badge and the status pill. Each encodes a specific business rule; building
  them once here is what stops individual screens re-deciding how to show a number.

  Colour and radius always come from the tokens in `assets/css/app.css` (`--color-*`,
  `--radius-field`, `--radius-chip`) via their generated Tailwind utilities
  (`bg-good`, `text-bad`, `rounded-chip`, …) — never a one-off hex value. The semantic
  assignment of a colour to a domain state (which token means "must-have gap", which
  means "invited") is **not** decided in this module; it lives in the table at
  `.claude/design/ui-decisions.md` §2 and is the caller's responsibility to apply
  correctly when choosing a `:severity` or `:tone` value. This module only enforces that
  `:accent` is never an option for either (see `status_pill/1`, `gap_severity/1`) —
  `:accent` is reserved for actions, never status, per that table.

  ## `formula/1`'s input shape — the `%Formula{}` contract (task 24)

  `formula/1` takes:

    * `:total` (`String.t()`, required) — the already-formatted, already-rounded
      headline result (e.g. the output of `WeddingPlannerWeb.Format.money/1`, or a
      plain count for a headcount formula). The component never formats or rounds a raw
      `Money.t()`, `Decimal.t()` or number itself.
    * `:total_label` (`String.t()`, default `"Total"`) — label shown next to `:total`.
    * `:steps` (`[%{label: String.t(), value: String.t()}]`, required) — the ordered,
      labelled inputs to the formula, in the exact order they must render. Each step's
      `:value` is likewise a pre-formatted display string, not a `Money.t()` or number.

  Two step kinds that are easy to special-case wrongly are **not** special-cased: the
  preset used (e.g. `%{label: "Preset used", value: "Likely"}`) and any minimum applied
  (e.g. `%{label: "Minimum charge applied", value: "€ 6.800,00"}`) are ordinary entries
  in this same `:steps` list, at whatever position they actually apply in the
  calculation — never separate assigns. `%Formula{}` (task 24) MUST therefore carry its
  steps as one ordered collection that already interleaves preset/minimum entries with
  line entries in calculation order, not as separate fields the renderer would need to
  reassemble.

  Why every value is a pre-formatted string rather than `Money.t()`: a formula step is
  not always money (a headcount formula's steps are counts; a preset-used step's value
  is a preset name, not an amount at all). Requiring every step's `:value` (and the
  overall `:total`) to already be a display string is what lets **one** renderer serve
  headcount (`HC-*`), offer totals (`CST-34`) and budget forecasts (`BUD-08`) alike,
  without teaching this component about `Money.t()`, `Decimal.t()`, or plain integers.
  Callers format money through `WeddingPlannerWeb.Format.money/1` — the only place
  rounding happens (`NFR-14`) — before handing a value to this component. Rounding
  itself is never this component's job; it only displays what it is given and states,
  in a standing caption, that the displayed steps may not sum to the displayed total by
  a cent because of that (`NFR-14`) — this is expected and is never reconciled here.

  ## `preset_selector/1`'s non-persistence guarantee (`HC-10`, `D-31`)

  The preset selector is a plain group of native `<input type="radio">` elements with no
  `phx-click`, `phx-change`, or any other server-facing wiring built into the component
  itself — the selected preset never leaves the browser's own DOM unless a caller
  deliberately adds that wiring around it (e.g. wrapping it in their own
  `<.form phx-change="...">`). This is the strongest available guarantee against
  accidental persistence: there is no assign, session key, URL param, PubSub topic or
  database row inside this component that could later be wired to a store by accident,
  because the component holds no state of its own to begin with — selection is native
  browser radio-button state. Each instance's `name` attribute is derived from its own
  `id` (`"\#{id}-preset"`), so two instances rendered on the same page are two entirely
  separate native radio groups: selecting one is a no-op on the other by ordinary HTML
  semantics, not anything this module has to arrange. If a caller does wire a
  `phx-change` around this component to recompute a value server-side, the resulting
  assign MUST stay in that LiveView's own transient socket assigns for the current
  connection only — never written to the database, the session, a PubSub broadcast, or
  any other cross-connection or cross-request store.
  """
  use Phoenix.Component

  import WeddingPlannerWeb.CoreComponents, only: [icon: 1]

  @doc """
  Renders the formula-expansion disclosure required by `CST-34`, `BUD-08` and `NFR-32`:
  every computed number must expand into its labelled inputs in **at most one
  interaction**. A native `<details>`/`<summary>` satisfies that for free, with zero
  JavaScript.

  See the moduledoc for the precise `:steps` input shape — in particular, the preset
  used and any minimum applied are ordinary entries in `:steps`, not separate assigns.

  The rounding caption (`NFR-14`) is about money rounding specifically, so it renders
  only when the formula has at least one money-valued step or a money total — never
  under a headcount-only formula (task 71), which has nothing to round. Money vs. count
  is decided by inspecting `:total` and each step's `:value` for the euro sign
  (`WeddingPlannerWeb.Format.money/1`'s only currency, `€`, `DR-17`), not by a flag the
  caller passes, so no call site needs to change. When shown, the caption is standing:
  it always renders, whether or not the steps you pass would actually sum to a
  different figure than `:total`, because this component cannot know that without
  redoing the calculation — and is not the place to.

  ## Examples

      <.formula
        id="offer-venue-a-total"
        total_label="Total (Likely)"
        total="€ 11.726,00"
        steps={[
          %{label: "Preset used", value: "Likely"},
          %{label: "Base price", value: "€ 4.000,00"},
          %{label: "Seating (78 − 50 included) × € 12,00", value: "€ 336,00"},
          %{label: "Catering, adults — minimum charge applied", value: "€ 6.800,00"},
          %{label: "Catering, children — 6 × € 40,00", value: "€ 240,00"},
          %{label: "Cleaning fee", value: "€ 350,00"}
        ]}
      />
  """
  attr :id, :string, required: true
  attr :total, :string, required: true
  attr :total_label, :string, default: "Total"
  attr :steps, :list, required: true, doc: "ordered [%{label: String.t(), value: String.t()}]"
  attr :summary, :string, default: "How is this calculated?"
  attr :open, :boolean, default: false, doc: "whether the disclosure starts expanded"

  def formula(assigns) do
    ~H"""
    <div id={@id} class="rounded-field border border-line bg-surface-raised">
      <div class="flex items-baseline justify-between gap-4 px-4 py-3">
        <span class="text-sm font-medium text-ink-soft">{@total_label}</span>
        <span id={"#{@id}-total"} class="tabular-nums text-base font-semibold text-ink">
          {@total}
        </span>
      </div>
      <details id={"#{@id}-disclosure"} open={@open} class="border-t border-line">
        <summary class="cursor-pointer list-none select-none px-4 py-2 text-sm font-medium text-ink-soft transition hover:text-ink focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-accent">
          {@summary}
        </summary>
        <div class="px-4 pb-4">
          <ol id={"#{@id}-steps"} class="divide-y divide-line">
            <li
              :for={{step, index} <- Enum.with_index(@steps)}
              id={"#{@id}-step-#{index}"}
              class="flex items-baseline justify-between gap-4 py-2 text-sm"
            >
              <span class="text-ink">{step.label}</span>
              <span class="tabular-nums shrink-0 text-ink">{step.value}</span>
            </li>
          </ol>
          <p
            :if={money_formula?(@total, @steps)}
            id={"#{@id}-caption"}
            class="mt-3 text-xs text-ink-faint"
          >
            Steps are rounded for display; the total above is calculated from unrounded
            amounts, so the steps may not sum exactly to it — by a cent. That is expected
            and is never corrected by rounding earlier.
          </p>
        </div>
      </details>
    </div>
    """
  end

  # NFR-14's rounding caption is about money, so it only renders when this formula has
  # a money-valued total or step. Every money display string comes from
  # `WeddingPlannerWeb.Format.money/1`, the app's only currency formatter (EUR-only,
  # `NFR-10`–`15`), so the presence of its euro sign is a reliable, flag-free signal —
  # a count, rate or preset-name step/total never contains one.
  defp money_formula?(total, steps) do
    money_value?(total) or Enum.any?(steps, &money_value?(&1.value))
  end

  defp money_value?(value) when is_binary(value), do: String.contains?(value, "€")

  @doc """
  Renders the minimum–maximum range required by `BUD-04` / `CST-53` and vision goal 2:
  "a guest-dependent cost is always shown as a range, never as a single number."

  Bounds are already-formatted display strings (typically
  `WeddingPlannerWeb.Format.money/1` output, or a plain headcount), so this component
  stays agnostic of whether the range measures money, a headcount, or anything else that
  depends on the guest list.

  ## Examples

      <.range id="venue-a-range" label="Total across presets" minimum="€ 11.478,00" maximum="€ 12.014,00" />
  """
  attr :id, :string, required: true
  attr :label, :string, default: nil
  attr :minimum, :string, required: true
  attr :maximum, :string, required: true

  def range(assigns) do
    ~H"""
    <div id={@id}>
      <span :if={@label} class="block text-xs font-medium tracking-wide text-ink-soft uppercase">
        {@label}
      </span>
      <p class="flex items-baseline gap-2 text-lg font-semibold text-ink">
        <span id={"#{@id}-minimum"} class="tabular-nums">{@minimum}</span>
        <span class="text-ink-faint" aria-hidden="true">–</span>
        <span id={"#{@id}-maximum"} class="tabular-nums">{@maximum}</span>
      </p>
    </div>
    """
  end

  @doc """
  Renders the headcount preset selector (`HC-08`, `HC-10`, `DR-54`, `D-31`) as a
  segmented control of **every** stored preset, in the order `:presets` is given (the
  caller passes `snapshot.headcount_presets`, already sorted). See the moduledoc for
  how its non-persistence is structurally enforced rather than merely documented.

  Once presets are renameable user data, this control can no longer assume three fixed
  names or values — `:presets` is `[%{id: term(), name: String.t()}]`, one chip per
  entry, radio `value` the preset's **id** (as a string), `:selected` the currently
  chosen id. Identity of which preset is the default single-figure choice belongs to
  the caller (`WeddingPlanner.Valuation.PresetChoice.default/1`, `DR-54`), not this
  component — it merely reflects whichever id `:selected` names as checked.

  A chip's label is the preset's full name, truncated **visually only** (`truncate
  max-w-*` plus a `title` attribute carrying the full name) — a long name is never
  dropped from the DOM or the accessible name, only clipped on screen.

  Wherever a count or per-person cost is shown using the preset this control selects,
  `HC-08` requires the preset in use to stay visible — satisfied for free when the value
  sits directly beside this control (its active chip *is* that label); if the value
  renders elsewhere in the layout, the caller needs its own explicit "(<name>)"-style
  label there.

  ## Examples

      <.preset_selector
        id="venue-preset"
        presets={[%{id: 1, name: "Minimum"}, %{id: 2, name: "Likely"}, %{id: 3, name: "Maximum"}]}
        selected={2}
      />
  """
  attr :id, :string, required: true
  attr :presets, :list, required: true, doc: "[%{id: term(), name: String.t()}]"
  attr :selected, :any, default: nil, doc: "the currently selected preset's id"

  def preset_selector(assigns) do
    ~H"""
    <fieldset id={@id} class="inline-flex flex-wrap gap-0.5 rounded-chip bg-surface p-0.5">
      <legend class="sr-only">Headcount preset</legend>
      <label :for={preset <- @presets} class="relative">
        <input
          type="radio"
          name={"#{@id}-preset"}
          id={"#{@id}-option-#{preset.id}"}
          value={preset.id}
          checked={to_string(preset.id) == to_string(@selected)}
          class="peer sr-only"
        />
        <span
          title={preset.name}
          class="block max-w-32 cursor-pointer truncate rounded-chip px-3 py-1 text-sm font-medium text-ink-soft transition hover:bg-line/40 peer-checked:bg-accent peer-checked:text-white peer-checked:hover:opacity-90 peer-focus-visible:ring-2 peer-focus-visible:ring-accent peer-focus-visible:ring-offset-1 peer-focus-visible:outline-none"
        >
          {preset.name}
        </span>
      </label>
    </fieldset>
    """
  end

  @doc """
  Renders the gap-severity treatment (`CST-25`, `CST-54`, `XC-42`): three visually
  distinct severities plus the invalid-line variant, which reuses the most prominent
  treatment with a different icon.

    * `:must_have` — prominent: solid bad-tone pill with an icon.
    * `:nice_to_have` — subtle: soft warn-tone **plain text**, no pill, no icon.
    * `:unknown` — neutral: dashed border, no fill, no icon ("ask the vendor" — absence
      of information is not a severity).
    * `:invalid` (`XC-42`) — prominent, same solid bad-tone pill as `:must_have`, but a
      different icon, so an invalid line is never mistaken for a plain must-have gap.

  ## Examples

      <.gap_severity id="venue-b-catering-gap" severity={:must_have} />
      <.gap_severity id="venue-b-sound-gap" severity={:nice_to_have} />
      <.gap_severity id="venue-a-snack-gap" severity={:unknown} />
      <.gap_severity id="offer-line-3" severity={:invalid} />
  """
  attr :id, :string, required: true
  attr :severity, :atom, required: true, values: [:must_have, :nice_to_have, :unknown, :invalid]
  attr :label, :string, default: nil

  def gap_severity(assigns) do
    # Not assign_new/3: the `label` attr's own `default: nil` already populates the
    # assign, so assign_new/3 (which only fills in a *missing* key) would never fire.
    label = assigns[:label] || default_gap_label(assigns.severity)
    assigns = assign(assigns, :label, label)

    ~H"""
    <span
      id={@id}
      data-severity={@severity}
      class={[
        "inline-flex items-center gap-1.5 text-xs font-medium",
        @severity != :nice_to_have && "rounded-chip px-2 py-0.5",
        gap_severity_class(@severity)
      ]}
    >
      <.icon
        :if={@severity == :must_have}
        name="hero-exclamation-triangle"
        class="size-3.5 shrink-0"
      />
      <.icon :if={@severity == :invalid} name="hero-no-symbol" class="size-3.5 shrink-0" />
      {@label}
    </span>
    """
  end

  defp default_gap_label(:must_have), do: "Must-have gap"
  defp default_gap_label(:nice_to_have), do: "Nice-to-have gap"
  defp default_gap_label(:unknown), do: "Ask the vendor"
  defp default_gap_label(:invalid), do: "Invalid line"

  defp gap_severity_class(:must_have), do: "bg-bad text-white"
  defp gap_severity_class(:nice_to_have), do: "text-warn"
  defp gap_severity_class(:unknown), do: "border border-dashed border-line-strong text-ink-faint"
  defp gap_severity_class(:invalid), do: "bg-bad text-white"

  @doc """
  Renders a status pill (invitation status, offer status, want tier, …), kept visually
  distinct from `gap_severity/1` so a status never reads as an alarm — even when the
  same colour token is legitimately shared between a status and a severity meaning (the
  `.claude/design/ui-decisions.md` §2 table assigns `--color-bad` to both "want tier:
  no" and "must-have gap"). The distinction is structural, not just colour: this
  component always renders a *soft*-tint pill with no icon and no solid fill, whereas
  `gap_severity/1`'s prominent treatments are solid-fill with an icon.

  `:tone` MUST be chosen from the semantic table in `.claude/design/ui-decisions.md` §2
  for the domain state being shown — never picked ad hoc at the call site. `:accent` is
  not a valid tone here: that table reserves it for actions, never status. `:neutral` is
  available for a status the table does not cover at all (e.g. an offer status like
  "considering" that carries no particular meaning yet).

  ## Examples

      <.status_pill id="invite-anna-dinner" label="Invited" tone={:info} />
      <.status_pill id="want-tier-bea" label="Maybe" tone={:warn} />
  """
  attr :id, :string, required: true
  attr :label, :string, required: true
  attr :tone, :atom, required: true, values: [:good, :warn, :bad, :info, :neutral]

  def status_pill(assigns) do
    ~H"""
    <span
      id={@id}
      data-tone={@tone}
      class={[
        "inline-flex items-center rounded-chip px-2 py-0.5 text-xs font-medium",
        status_pill_class(@tone)
      ]}
    >
      {@label}
    </span>
    """
  end

  defp status_pill_class(:good), do: "bg-good-soft text-good"
  defp status_pill_class(:warn), do: "bg-warn-soft text-warn"
  defp status_pill_class(:bad), do: "bg-bad-soft text-bad"
  defp status_pill_class(:info), do: "bg-info-soft text-info"
  defp status_pill_class(:neutral), do: "bg-surface text-ink-soft"
end
