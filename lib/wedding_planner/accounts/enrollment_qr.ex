defmodule WeddingPlanner.Accounts.EnrollmentQr do
  @moduledoc """
  AUTH-06: renders an enrollment link's URL as an inline SVG QR code, shown together with
  the copyable URL on both the generation screen and (implicitly, since it is the same
  render) anywhere else a link's card is displayed.

  `eqrcode` does the encoding (pure Elixir, no JS, nothing fetched at render time). Its
  own `EQRCode.svg/2` emits one `<rect>` per module — including every *white* one, about
  84 KB of markup for a single enrollment URL, which LiveView would re-diff on every
  render. Walking the matrix into a single `<path>` instead gives the same image in a few
  KB, so that is what this module does. A test asserts the rendered SVG stays under 10 KB
  to guard against this trap coming back.

  The result is safe to drop into HEEx with `{Phoenix.HTML.raw/1}`: the only text that
  comes from outside is the URL, and the URL itself never reaches the SVG markup — only
  its encoded module matrix does.
  """

  @doc """
  Returns an SVG document (as a string) encoding `url`.

  Options:

    * `:size` - rendered pixel size of the square (default 240)
    * `:quiet_zone` - modules of white margin (default 2; the spec asks for 4, 2 is
      enough in practice on a screen and keeps the code larger)
    * `:dark` / `:light` - CSS colours
  """
  @spec svg(String.t(), keyword()) :: String.t()
  def svg(url, opts \\ []) when is_binary(url) do
    size = Keyword.get(opts, :size, 240)
    quiet = Keyword.get(opts, :quiet_zone, 2)
    dark = Keyword.get(opts, :dark, "#211D18")
    light = Keyword.get(opts, :light, "#ffffff")

    rows = url |> EQRCode.encode() |> Map.fetch!(:matrix) |> Tuple.to_list()
    n = length(rows)
    box = n + 2 * quiet

    path =
      rows
      |> Enum.with_index()
      |> Enum.flat_map(fn {row, y} ->
        row
        |> Tuple.to_list()
        |> Enum.with_index()
        |> runs()
        |> Enum.map(fn {x, len} -> "M#{x + quiet} #{y + quiet}h#{len}v1h-#{len}z" end)
      end)
      |> Enum.join()

    """
    <svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 #{box} #{box}" \
    width="#{size}" height="#{size}" shape-rendering="crispEdges" role="img" \
    aria-label="Enrollment link QR code">\
    <rect width="#{box}" height="#{box}" fill="#{light}"/>\
    <path fill="#{dark}" d="#{path}"/>\
    </svg>\
    """
  end

  # Collapses each row of dark modules into horizontal runs: {start_x, length}.
  defp runs(indexed_row) do
    indexed_row
    |> Enum.reduce({[], nil}, fn
      {1, x}, {acc, nil} -> {acc, {x, 1}}
      {1, _x}, {acc, {start, len}} -> {acc, {start, len + 1}}
      {_dark_0, _x}, {acc, nil} -> {acc, nil}
      {_dark_0, _x}, {acc, run} -> {[run | acc], nil}
    end)
    |> then(fn
      {acc, nil} -> Enum.reverse(acc)
      {acc, run} -> Enum.reverse([run | acc])
    end)
  end
end
