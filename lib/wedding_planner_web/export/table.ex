defmodule WeddingPlannerWeb.Export.Table do
  @moduledoc """
  The plain-map shape every exporter (`WeddingPlannerWeb.Export.Exporter`) hands to
  `WeddingPlannerWeb.Export.Csv.encode/1` (`DR-86`, `DR-87`, `DR-88`; contract shared
  verbatim with task 93, `.claude/plans/w14-plan.md` §5).

  Deliberately **not** a struct: a `t()` is just `%{stem:, headers:, rows:}`, so a test can
  build one with a bare map literal.

    * `stem` — the export's file stem (`"persons"`, `"headcount"`, …), used to build the
      download's filename (`WeddingPlannerWeb.ExportController`).
    * `headers` — the header row, in English (`NFR-30`), one preset-dependent column named
      after its preset (`HC-08`) where relevant. Never empty.
    * `rows` — the body. **Every row's length MUST equal `headers`'s** — the encoder
      raises otherwise (`DR-86`).

  ## Cells (`DR-86`)

  A table with money has **one** `"Currency"` column, **last**, holding the row's
  currency code as a string (`"EUR"`, taken from a `%Money{}` in that row — `NFR-15`), or
  `nil` when the row has no amount at all. `WeddingPlannerWeb.Export.Csv` raises if a
  row's `%Money{}` cells disagree on currency.
  """

  @typedoc """
  One exportable cell — everything `WeddingPlannerWeb.Export.Csv.encode/1` knows how to
  render. An unknown term raises (a caller bug, `DR-86`).
  """
  @type cell :: String.t() | integer() | Decimal.t() | Date.t() | Money.t() | boolean() | nil

  @typedoc "See the moduledoc."
  @type t :: %{stem: String.t(), headers: [String.t(), ...], rows: [[cell()]]}
end
