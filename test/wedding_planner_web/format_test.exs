defmodule WeddingPlannerWeb.FormatTest do
  # `default_time_zone/0` now reads the stored `WeddingPlanner.Settings` singleton
  # (NFR-22 — see that module's moduledoc), so this suite needs a database connection;
  # `DataCase` is `ExUnit.Case` plus the SQL sandbox, so the doctests below (which
  # exercise `resolve_time_zone/1` and `datetime/2`'s fallback branches) still run.
  use WeddingPlanner.DataCase, async: true

  alias WeddingPlannerWeb.Format, as: Subject

  doctest WeddingPlannerWeb.Format

  describe "date/1 — NFR-20, NFR-23" do
    test "formats a Date day-first (dd/mm/yyyy)" do
      assert Subject.date(~D[2026-09-21]) == "21/09/2026"
    end

    test "pads single-digit day and month" do
      assert Subject.date(~D[2026-01-05]) == "05/01/2026"
    end

    test "never touches a time zone — a Date near a UTC midnight boundary does not shift" do
      # If a Date were ever routed through a time zone conversion (the NFR-20 violation
      # this module exists to prevent), a date adjacent to a UTC day boundary would be
      # the first place that broke. date/1 doesn't even accept a time zone argument, so
      # there is no code path that could shift it.
      assert Subject.date(~D[2026-01-01]) == "01/01/2026"
      assert Subject.date(~D[2025-12-31]) == "31/12/2025"
    end

    test "handles the 'No date yet' case explicitly (EVT-03), not as blank" do
      assert Subject.date(nil) == "No date yet"
    end
  end

  describe "datetime/2 — NFR-21, NFR-22, NFR-23" do
    test "renders a UTC moment in Europe/Brussels during CEST (summer, +2)" do
      assert Subject.datetime(~U[2026-09-23 10:00:00Z], "Europe/Brussels") ==
               "23/09/2026 12:00"
    end

    test "renders a UTC moment in Europe/Brussels during CET (winter, +1) — DST boundary" do
      assert Subject.datetime(~U[2026-01-15 10:00:00Z], "Europe/Brussels") ==
               "15/01/2026 11:00"
    end

    test "a moment just before UTC midnight correctly rolls over to the next local day" do
      # 2026-01-01 23:30 UTC is winter (CET, +1), so local time is 2026-01-02 00:30 — the
      # calendar day is different from the UTC day. This is the correct, expected shift
      # for a DateTime (NFR-21/22) — unlike a Date, which must never shift (see date/1's
      # "does not shift" test above).
      assert Subject.datetime(~U[2026-01-01 23:30:00Z], "Europe/Brussels") ==
               "02/01/2026 00:30"
    end

    test "a moment just after UTC midnight correctly stays on the previous local day in a negative-ish case too" do
      # 2026-06-01 00:15 UTC is summer (CEST, +2), so local time is 2026-06-01 02:15 —
      # same day here, but exercises the conversion path independently of the rollover
      # case above.
      assert Subject.datetime(~U[2026-06-01 00:15:00Z], "Europe/Brussels") ==
               "01/06/2026 02:15"
    end

    test "falls back to the configured default when no zone is supplied" do
      assert Subject.datetime(~U[2026-09-23 10:00:00Z], nil) ==
               Subject.datetime(~U[2026-09-23 10:00:00Z], Subject.default_time_zone())
    end
  end

  describe "resolve_time_zone/1 — NFR-22, total fallback" do
    test "returns a valid IANA zone unchanged" do
      assert Subject.resolve_time_zone("Europe/Brussels") == "Europe/Brussels"
      assert Subject.resolve_time_zone("America/New_York") == "America/New_York"
    end

    test "falls back to the default when given nil" do
      assert Subject.resolve_time_zone(nil) == Subject.default_time_zone()
    end

    test "falls back to the default when given an empty string" do
      assert Subject.resolve_time_zone("") == Subject.default_time_zone()
    end

    test "falls back to the default when given an unparseable/unknown zone, without raising" do
      assert Subject.resolve_time_zone("not a real zone") == Subject.default_time_zone()
      assert Subject.resolve_time_zone("Mars/Olympus_Mons") == Subject.default_time_zone()
    end

    test "falls back to the default when given a non-binary value, without raising" do
      assert Subject.resolve_time_zone(123) == Subject.default_time_zone()
      assert Subject.resolve_time_zone(%{}) == Subject.default_time_zone()
    end
  end

  describe "default_time_zone/0 — NFR-22, stored setting (not raw config)" do
    test "reads WeddingPlanner.Settings' stored default_time_zone" do
      assert Subject.default_time_zone() == WeddingPlanner.Settings.get().default_time_zone
    end

    test "is Europe/Brussels before anyone edits it, seeded from application config" do
      assert Subject.default_time_zone() == "Europe/Brussels"
    end

    test "follows an edit to the stored setting, not the application config value" do
      settings = WeddingPlanner.Settings.get()

      user =
        WeddingPlanner.Repo.insert!(
          WeddingPlanner.Accounts.User.changeset(%WeddingPlanner.Accounts.User{}, %{
            display_name: "Wannes"
          })
        )

      scope = WeddingPlanner.Accounts.Scope.for_user(user)

      {:ok, _updated} =
        WeddingPlanner.Settings.update(scope, settings, %{
          "default_time_zone" => "Europe/Amsterdam"
        })

      assert Subject.default_time_zone() == "Europe/Amsterdam"
      # The application config value never changed — only the stored row did.
      assert Application.get_env(:wedding_planner, :default_time_zone) == "Europe/Brussels"
    end
  end

  describe "money/1 — NFR-14, DR-18" do
    test "rounds to the currency's minor unit at the display boundary" do
      unrounded = WeddingPlanner.Money.new(Decimal.new("42.567"))
      assert Subject.money(unrounded) == "€ 42,57"
    end

    test "renders in the nl-BE form: leading euro sign, NBSP, dot thousands, comma decimal" do
      assert Subject.money(WeddingPlanner.Money.new(7641)) == "€ 7.641,00"
    end

    test "the underlying WeddingPlanner.Money kernel never rounds — only the formatter does" do
      unrounded =
        WeddingPlanner.Money.gross_up(WeddingPlanner.Money.new(100), Decimal.new("0.21356"))

      # The kernel (NFR-14) keeps full precision: the raw amount still carries 5 decimal
      # digits here, not 2 — nothing along the WeddingPlanner.Money chain rounded it.
      assert Decimal.to_string(unrounded.amount) == "121.35600"

      # Format.money/1 is where NFR-14 rounding happens, and only here.
      assert Subject.money(unrounded) == "€ 121,36"
    end
  end
end
