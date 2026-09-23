defmodule WeddingPlanner.Settings do
  @moduledoc """
  The application-wide settings singleton (`docs/03-domain-model.md`'s Settings entity):
  the **overall budget** (`BUD-01`) and the **default time zone** (`NFR-22`). Not related
  to anything else — these two values belong to the application, not to any entity.

  This one module is deliberately both the schema and the read/write API. Every other
  entity in this app has a separate query/write module (`WeddingPlanner.Log` /
  `WeddingPlanner.Log.Query` / `WeddingPlanner.Log.Entry`) because there are many rows
  and several access patterns to keep apart; a singleton has exactly one row and exactly
  one access pattern (`get/0`, `update/3`), so splitting it across files would only add
  indirection.

  ## Singleton-ness, enforced in the database

  `get/0` never returns `nil` — it creates the row (with sane defaults) on first access
  if it does not exist yet, race-safely (see `get_or_create/0`). But the real guarantee
  is not that function; it is the migration
  (`priv/repo/migrations/*_create_settings.exs`): the primary key is fixed to the
  literal integer `1` via a `CHECK (id = 1)` constraint, so a second row is impossible at
  the storage layer, not merely discouraged by convention — an insert with `id = 1` when
  the row already exists violates the PRIMARY KEY's uniqueness, and an insert with any
  other `id` violates the CHECK. Both were verified directly against SQLite while this
  migration was written (a raw second-row insert attempt was rejected with `UNIQUE
  constraint failed: settings.id` / `CHECK constraint failed: settings_singleton_id`).

  ## Stored vs. configured time zone (`NFR-22`, a decision the roadmap calls out)

  There are two candidate "default time zone" values, and they play different roles:

    * `config :wedding_planner, :default_time_zone` — application **configuration**. Its
      only job is to seed this row's `default_time_zone` column **the one time** the row
      is created (`get_or_create/0`). It is never consulted again after that.
    * `settings.default_time_zone` (this schema's column) — the **stored, app-level
      setting**. Once the row exists, this is the value the rest of the app treats as
      "the default time zone" (`WeddingPlannerWeb.Format.default_time_zone/0` and
      `WeddingPlannerWeb.Live.TimeZoneHook` both read it — see those modules' moduledocs
      for the one-read-at-mount wiring).

  In short: configuration is the seed, the database row is the setting. Editing the
  setting on the `/settings` page never touches application configuration, and changing
  the configuration after the row exists has no further effect.

  ## Overall budget: unset is a real state, not €0,00 (`BUD-01`)

  `overall_budget` is nilable and starts `nil` — "Not set", not a fake zero figure. This
  was flagged to the user rather than assumed silently: showing €0,00 before anyone has
  entered a number would misrepresent the couple's finances, since a real €0,00 budget
  and "nobody has typed a number yet" are not the same fact.

  ## Money input (`DR-23`)

  `overall_budget_input` is a virtual field carrying whatever the user typed in the form
  (a raw nl-BE amount string, or the empty string to clear the budget). `changeset/2`
  parses it via `WeddingPlanner.Money.parse/1` and, on success, sets the real
  `overall_budget` field from the resulting `%Money{}` — the form never binds directly to
  `overall_budget` itself, since that field only ever holds a `%Money{}` or `nil`, never
  user-typed text (`DR-18`: money is never constructed from a raw string).

  ## Activity log and live updates (`XC-10`, `XC-01`)

  `update/3` writes one `WeddingPlanner.Log` entry **per field that actually changed**
  (not a bulk-action summary via `Log.action/3` — this is a single entity, not several,
  so `XC-12`'s summary/children shape does not apply), each phrased as a transition
  ("Wannes changed the overall budget: Not set → € 45.000,00"). The settings row's
  ordinary `Repo.update/2` write is already atomic on its own, so each entry is written
  via a standalone `Log.entry/3` call *after* the write succeeds — this is the "called on
  its own" path `WeddingPlanner.Log`'s moduledoc documents as broadcasting at the correct
  moment (immediately after its own insert, which is also the commit), rather than
  wrapping everything in a second, redundant transaction.

  Every successful update also broadcasts the whole updated struct via
  `WeddingPlanner.Realtime.broadcast_change(:settings, {:updated, settings})` so every
  open `/settings` page updates live (`XC-01`). Per `DR-21`/`XC-02`, there is no
  concurrent-edit indicator of any kind — a broadcast just replaces what is shown, same
  as any other resource on this convention.
  """

  use Ecto.Schema

  import Ecto.Changeset

  alias WeddingPlanner.Accounts.Scope
  alias WeddingPlanner.Log
  alias WeddingPlanner.Realtime
  alias WeddingPlanner.Repo
  alias WeddingPlannerWeb.Format

  @singleton_id 1

  @type t :: %__MODULE__{}

  @primary_key {:id, :integer, autogenerate: false}

  schema "settings" do
    field :overall_budget, Money.Ecto.Map.Type
    field :overall_budget_input, :string, virtual: true
    field :default_time_zone, :string

    timestamps(type: :utc_datetime)
  end

  @doc """
  Always returns the settings singleton, creating it (overall budget unset, default time
  zone seeded from `config :wedding_planner, :default_time_zone` — see the moduledoc) on
  first access. Callers never have to handle `nil`.
  """
  @spec get() :: t()
  def get do
    case Repo.get(__MODULE__, @singleton_id) do
      nil -> get_or_create()
      settings -> settings
    end
  end

  @doc """
  Changeset for editing the singleton (`BUD-01`, `NFR-22`).

  `attrs` may include:

    * `"overall_budget_input"` — a raw nl-BE amount string, parsed via
      `WeddingPlanner.Money.parse/1` (`DR-23`). The empty string clears the budget back
      to unset (`nil`); omitting the key entirely leaves the stored budget untouched.
    * `"default_time_zone"` — an IANA zone name, validated against the real zone list of
      the configured `Tz` time zone database (the same mechanism
      `WeddingPlannerWeb.Format.resolve_time_zone/1` uses), not a hard-coded list.
  """
  @spec changeset(t(), map()) :: Ecto.Changeset.t()
  def changeset(settings, attrs) do
    settings
    # `empty_values: []` disables `cast/4`'s default treatment of `""` as "field not
    # provided" — `overall_budget_input` MUST distinguish an omitted key (leave the
    # stored budget alone) from an explicit empty string (clear it back to unset, see
    # `put_overall_budget/1`), and the default behaviour collapses both to the same
    # no-op.
    |> cast(attrs, [:overall_budget_input, :default_time_zone], empty_values: [])
    |> validate_required([:default_time_zone])
    |> validate_time_zone()
    |> put_overall_budget()
  end

  @doc """
  Applies `attrs` (see `changeset/2`) to `settings`, writing one activity entry per
  changed field (`XC-10`) and broadcasting the update (`XC-01`) on success.
  """
  @spec update(Scope.t(), t(), map()) :: {:ok, t()} | {:error, Ecto.Changeset.t()}
  def update(%Scope{} = scope, %__MODULE__{} = settings, attrs) do
    changeset = changeset(settings, attrs)

    budget_description = budget_transition_description(scope, changeset)
    zone_description = zone_transition_description(scope, changeset)

    case Repo.update(changeset) do
      {:ok, updated} ->
        if budget_description do
          {:ok, _entry} = Log.entry(scope, {:settings, updated.id}, budget_description)
        end

        if zone_description do
          {:ok, _entry} = Log.entry(scope, {:settings, updated.id}, zone_description)
        end

        Realtime.broadcast_change(:settings, {:updated, updated})
        {:ok, updated}

      {:error, _changeset} = error ->
        error
    end
  end

  # Race-safe first-access creation (mirrors `WeddingPlanner.Accounts.Setup.
  # create_first_user/1`'s `DR-22`-style guard): a `mode: :immediate` transaction makes a
  # second concurrent caller's own `BEGIN IMMEDIATE` block until the first commits, so by
  # the time it re-checks, the row it was racing to create already exists.
  defp get_or_create do
    {:ok, settings} =
      Repo.transaction(
        fn ->
          case Repo.get(__MODULE__, @singleton_id) do
            nil ->
              %__MODULE__{id: @singleton_id}
              |> changeset(%{"default_time_zone" => configured_default_time_zone()})
              |> Repo.insert!()

            existing ->
              existing
          end
        end,
        mode: :immediate
      )

    settings
  end

  # The row does not exist yet, so there is no stored value to read — this is the one
  # place application configuration is consulted directly (never via
  # `WeddingPlannerWeb.Format.default_time_zone/0`, which after this task instead reads
  # the stored setting; going through it here would recurse: Format would call `get/0`,
  # which would call `get_or_create/0`, which would call Format again, forever).
  defp configured_default_time_zone do
    Application.get_env(:wedding_planner, :default_time_zone, "Europe/Brussels")
  end

  defp validate_time_zone(changeset) do
    validate_change(changeset, :default_time_zone, fn :default_time_zone, zone ->
      case DateTime.shift_zone(DateTime.utc_now(), zone) do
        {:ok, _shifted} -> []
        {:error, _reason} -> [default_time_zone: "is not a recognized time zone"]
      end
    end)
  end

  defp put_overall_budget(changeset) do
    case get_change(changeset, :overall_budget_input) do
      nil ->
        changeset

      "" ->
        put_change(changeset, :overall_budget, nil)

      raw when is_binary(raw) ->
        case WeddingPlanner.Money.parse(raw) do
          {:ok, money} -> put_change(changeset, :overall_budget, money)
          {:error, message} -> add_error(changeset, :overall_budget_input, message)
        end
    end
  end

  defp budget_transition_description(scope, changeset) do
    case fetch_change(changeset, :overall_budget) do
      {:ok, new_budget} ->
        old_budget = changeset.data.overall_budget

        "#{actor_name(scope)} changed the overall budget: " <>
          "#{budget_label(old_budget)} → #{budget_label(new_budget)}"

      :error ->
        nil
    end
  end

  defp zone_transition_description(scope, changeset) do
    case fetch_change(changeset, :default_time_zone) do
      {:ok, new_zone} ->
        old_zone = changeset.data.default_time_zone

        "#{actor_name(scope)} changed the default time zone: #{old_zone} → #{new_zone}"

      :error ->
        nil
    end
  end

  @doc """
  The label shown for the overall budget (`BUD-01`): the formatted amount, or the
  explicit `"Not set"` placeholder for `nil` — never a fake `€ 0,00`. Shared by the
  activity-entry transition descriptions above and `WeddingPlannerWeb.Live.SettingsLive`.
  """
  @spec budget_label(Money.t() | nil) :: String.t()
  def budget_label(nil), do: "Not set"
  def budget_label(%Money{} = money), do: Format.money(money)

  defp actor_name(%Scope{user: %{display_name: name}}) when is_binary(name), do: name
  defp actor_name(_scope), do: "Someone"
end
