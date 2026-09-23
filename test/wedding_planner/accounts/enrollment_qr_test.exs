defmodule WeddingPlanner.Accounts.EnrollmentQrTest do
  @moduledoc """
  AUTH-06's QR requirement, plus the specific performance trap called out in
  `.claude/tasks/16-enrollment-links.md`: `EQRCode.svg/2` emits one `<rect>` per module
  (including white ones), about 84 KB for a single enrollment URL —
  `WeddingPlanner.Accounts.EnrollmentQr` walks the matrix into a single `<path>` instead,
  which must stay comfortably under 10 KB.
  """
  use ExUnit.Case, async: true

  alias WeddingPlanner.Accounts.EnrollmentQr

  @url "http://localhost:4000/enroll/UDDIC8vAQ2Kx8N8f_1YQ2n0h7q9c4b1e3f5a7c9e1b3d5f7a9c1e3b5d7f9a1c3e5"

  test "renders a single-<path> SVG under 10KB" do
    svg = EnrollmentQr.svg(@url)

    assert byte_size(svg) < 10_000
    assert svg =~ "<svg"
    assert svg =~ "</svg>"

    # Exactly one <path> element carries every dark module — the whole point of walking
    # the matrix by hand instead of using EQRCode.svg/2's one-<rect>-per-module output.
    assert length(String.split(svg, "<path")) == 2
    refute svg =~ "<rect width=\"1\""
  end

  test "encodes the URL into the matrix, not into the markup as text" do
    svg = EnrollmentQr.svg(@url)

    refute svg =~ @url
  end

  test "is stable and deterministic for the same URL" do
    assert EnrollmentQr.svg(@url) == EnrollmentQr.svg(@url)
  end

  test "different URLs produce different codes" do
    refute EnrollmentQr.svg(@url) == EnrollmentQr.svg(@url <> "x")
  end

  test "respects the :size option" do
    svg = EnrollmentQr.svg(@url, size: 96)

    assert svg =~ ~s(width="96")
    assert svg =~ ~s(height="96")
  end
end
