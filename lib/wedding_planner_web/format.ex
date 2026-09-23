defmodule WeddingPlannerWeb.Format do
  @moduledoc """
  The single display-formatting layer for dates, timestamps and money (`05-non-functional.md`).

  Every view, component and CSV export MUST render these three kinds of value through this
  module rather than re-deciding the format at the call site.

  ## Dates vs. moments (`NFR-20` / `NFR-21`)

  This is the distinction to get right:

    * A **calendar date** (`Date.t()` — event dates, fixed task deadlines, invoice dates, due
      dates, paid dates) is stored with no time and no time zone, and `date/1` **never**
      converts it through a time zone. Doing so can shift it by a day, which is the entire
      reason `NFR-20` exists.
    * A **moment in time** (`DateTime.t()` — activity entries, record timestamps, passkey
      usage, enrollment link expiry) is always stored as UTC and only ever converted to a
      time zone here, at the display boundary (`NFR-21`).

  ## Time zone (`NFR-22`)

  `datetime/2` displays a UTC moment in the time zone reported by the viewer's browser
  (see `WeddingPlannerWeb.Live.TimeZoneHook`), falling back to the **stored** default
  (`default_time_zone/0`) when the browser reports nothing, or reports something that is
  not a real IANA zone. `resolve_time_zone/1` is total: it never raises, whatever it is
  given.

  `default_time_zone/0` reads `WeddingPlanner.Settings.get/0`'s `default_time_zone`
  column, **not** application configuration directly — see that module's moduledoc for
  why (`config :wedding_planner, :default_time_zone` only seeds the stored value the one
  time the settings row is first created; after that, the stored value is the app-level
  setting, editable on `/settings`, and configuration is no longer consulted). This is a
  cheap, single primary-key lookup, not a hot-path concern: `TimeZoneHook` calls it at
  most once per LiveView mount (`assign_new/3`), and every other caller in a render loop
  reuses the resulting `@time_zone` assign rather than calling this function again.

  ## Day-first, always (`NFR-23`, `D-24`)

  Every date renders `dd/mm/yyyy` (e.g. `21/09/2026`), including in CSV exports. There is no
  locale detection and no per-user format setting — the browser only reports language, not
  regional format, and would otherwise yield US-style dates.

  ## "No date yet" (`EVT-03`)

  An event's date may be unknown. `date/1` accepts `nil` and returns an explicit placeholder
  ("No date yet") rather than letting a `nil` render blank.

  **Flag for whoever builds `docs/modules/tasks-and-timeline.md`'s `TSK-03`**: that rule's own
  normative example quotes a *different* string verbatim — "8 weeks before Civil ceremony —
  date not set" — for an unresolved relative deadline (a different situation: the deadline
  itself can't be computed, not that an event's own date field is blank). If that feature ends
  up composing its message by calling `date/1` directly, the two will disagree; either reuse a
  distinct, purpose-built string there or update `TSK-03`'s example to match this placeholder.
  Not reconciled here since that module doesn't exist yet.

  ## Money rounding (`NFR-14`, `DR-25`)

  `money/1` is the **only** place rounding to the currency's minor unit is allowed. Every
  `WeddingPlanner.Money` function keeps full, unrounded precision all the way through a
  calculation chain; rounding happens once, here, at the point a value is displayed.

  The rounding mode is **half-up** (`DR-25`), not ex_money's default banker's rounding
  (`:half_even`): `10,005` displays as `€ 10,01`, and `10,025` as `€ 10,03` where banker's
  rounding would give `€ 10,02`. Half-up is what people expect on a price and what
  spreadsheets and invoices do. This being the one rounding site, the mode is decided here
  and nowhere else.
  """

  @date_not_set "No date yet"

  @doc """
  Formats a calendar date `dd/mm/yyyy` (`NFR-23`), or the explicit "No date yet" placeholder
  for `nil` (`EVT-03`).

  Never converts through a time zone (`NFR-20`) — there is no time zone parameter to pass.

  ## Examples

      iex> WeddingPlannerWeb.Format.date(~D[2026-09-21])
      "21/09/2026"

      iex> WeddingPlannerWeb.Format.date(nil)
      "No date yet"

  """
  @spec date(Date.t() | nil) :: String.t()
  def date(nil), do: @date_not_set

  def date(%Date{} = date) do
    Calendar.strftime(date, "%d/%m/%Y")
  end

  @doc """
  Formats a UTC moment (`NFR-21`) as `dd/mm/yyyy HH:MM` in the given IANA time zone.

  `time_zone` is normally the value reported by `WeddingPlannerWeb.Live.TimeZoneHook`. It is
  resolved through `resolve_time_zone/1`, so `nil` or an unparseable zone falls back to the
  configured default (`NFR-22`) instead of raising.

  ## Examples

      iex> WeddingPlannerWeb.Format.datetime(~U[2026-09-23 10:00:00Z], "Europe/Brussels")
      "23/09/2026 12:00"

      iex> WeddingPlannerWeb.Format.datetime(~U[2026-01-15 10:00:00Z], "Europe/Brussels")
      "15/01/2026 11:00"

      iex> WeddingPlannerWeb.Format.datetime(~U[2026-09-23 10:00:00Z], nil)
      "23/09/2026 12:00"

  """
  @spec datetime(DateTime.t(), String.t() | nil) :: String.t()
  def datetime(%DateTime{} = datetime, time_zone \\ nil) do
    zone = resolve_time_zone(time_zone)

    datetime
    |> DateTime.shift_zone!(zone)
    |> Calendar.strftime("%d/%m/%Y %H:%M")
  end

  @doc """
  Resolves a candidate IANA time zone name to a usable one, falling back to
  `default_time_zone/0` when `zone` is `nil`, not a binary, or not a real time zone
  (`NFR-22`). Total — never raises, whatever it is given.

  ## Examples

      iex> WeddingPlannerWeb.Format.resolve_time_zone("Europe/Brussels")
      "Europe/Brussels"

      iex> WeddingPlannerWeb.Format.resolve_time_zone(nil)
      "Europe/Brussels"

      iex> WeddingPlannerWeb.Format.resolve_time_zone("not a real zone")
      "Europe/Brussels"

      iex> WeddingPlannerWeb.Format.resolve_time_zone("")
      "Europe/Brussels"

  """
  @spec resolve_time_zone(String.t() | nil) :: String.t()
  def resolve_time_zone(zone) when is_binary(zone) and zone != "" do
    case DateTime.shift_zone(DateTime.utc_now(), zone) do
      {:ok, _shifted} -> zone
      {:error, _reason} -> default_time_zone()
    end
  end

  def resolve_time_zone(_zone), do: default_time_zone()

  @doc """
  The app-wide fallback time zone (`NFR-22`) — the **stored** value from
  `WeddingPlanner.Settings.get/0`, seeded from application configuration only the one
  time the settings row is first created. See the moduledoc's "Time zone" section.
  """
  @spec default_time_zone() :: String.t()
  def default_time_zone do
    WeddingPlanner.Settings.get().default_time_zone
  end

  @doc """
  Formats a `%Money{}` for display, rounding **half-up** to the currency's minor unit
  (`Money.round/2` with `rounding_mode: :half_up`, `DR-25`). This is the **only** place
  rounding is allowed (`NFR-14`) — every value arrives here at full, unrounded precision.

  ## Examples

      iex> WeddingPlannerWeb.Format.money(WeddingPlanner.Money.new(Decimal.new("42.567")))
      "€ 42,57"

      iex> WeddingPlannerWeb.Format.money(WeddingPlanner.Money.new(Decimal.new("10.025")))
      "€ 10,03"

      iex> WeddingPlannerWeb.Format.money(WeddingPlanner.Money.new(7641))
      "€ 7.641,00"

  """
  @spec money(Money.t()) :: String.t()
  def money(%Money{} = amount) do
    amount
    |> Money.round(rounding_mode: :half_up)
    |> Money.to_string!()
  end
end
