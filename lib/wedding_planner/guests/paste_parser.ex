defmodule WeddingPlanner.Guests.PasteParser do
  @moduledoc """
  Splits pasted guest-list text into first/last name pairs (`DR-26` Q5,
  `.claude/plans/w6-plan.md`), one entry per non-blank line, in input order. Pure: no
  Ecto, no database access — `WeddingPlanner.Guests.bulk_create_persons/3` is what turns
  a parsed entry into a `WeddingPlanner.Guests.Person`.

  ## The splitting rule (Q5)

  Each non-blank line is trimmed, then:

    1. a line containing a **tab** splits at the first tab into first name / last name
       (columns pasted from a spreadsheet);
    2. otherwise a line containing a **comma** is read as `"Last, First"`, split at the
       first comma;
    3. otherwise the line is split on whitespace: a single token is a first name only
       ("Bo", "Oma"); more than one token makes the first token the first name and every
       remaining token — rejoined with a single space — the last name ("Jan Van Damme"
       → Jan / Van Damme; "Anna Marie Peeters" → Anna / Marie Peeters).

  Internal whitespace in either resulting part collapses to a single space. A line that
  yields neither a first nor a last name (e.g. a bare `","`) is an error.
  """

  @type entry :: %{first_name: String.t() | nil, last_name: String.t() | nil}
  @type result :: {:ok, entry()} | {:error, String.t(), String.t()}

  @doc """
  Parses pasted text into one result per non-blank line, in input order.

  ## Examples

      iex> WeddingPlanner.Guests.PasteParser.parse("Jan Van Damme")
      [{:ok, %{first_name: "Jan", last_name: "Van Damme"}}]

      iex> WeddingPlanner.Guests.PasteParser.parse("Van Damme, Jan")
      [{:ok, %{first_name: "Jan", last_name: "Van Damme"}}]

      iex> WeddingPlanner.Guests.PasteParser.parse("Jan\\tVan Damme")
      [{:ok, %{first_name: "Jan", last_name: "Van Damme"}}]

      iex> WeddingPlanner.Guests.PasteParser.parse("Bo")
      [{:ok, %{first_name: "Bo", last_name: nil}}]

      iex> WeddingPlanner.Guests.PasteParser.parse("Anna Marie Peeters")
      [{:ok, %{first_name: "Anna", last_name: "Marie Peeters"}}]

      iex> WeddingPlanner.Guests.PasteParser.parse("Jan   Van   Damme")
      [{:ok, %{first_name: "Jan", last_name: "Van Damme"}}]

      iex> WeddingPlanner.Guests.PasteParser.parse("\\n  \\nBo\\n")
      [{:ok, %{first_name: "Bo", last_name: nil}}]

      iex> WeddingPlanner.Guests.PasteParser.parse(",")
      [{:error, ",", "no name found"}]
  """
  @spec parse(String.t()) :: [result()]
  def parse(text) when is_binary(text) do
    text
    |> String.split(["\r\n", "\r", "\n"])
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == ""))
    |> Enum.map(&parse_line/1)
  end

  defp parse_line(line) do
    cond do
      String.contains?(line, "\t") -> split_columns(line)
      String.contains?(line, ",") -> split_last_first(line)
      true -> split_whitespace(line)
    end
  end

  defp split_columns(line) do
    [first, last] = String.split(line, "\t", parts: 2)
    build(line, normalize(first), normalize(last))
  end

  defp split_last_first(line) do
    [last, first] = String.split(line, ",", parts: 2)
    build(line, normalize(first), normalize(last))
  end

  defp split_whitespace(line) do
    case String.split(line) do
      [] -> {:error, line, "no name found"}
      [only] -> build(line, normalize(only), nil)
      [first | rest] -> build(line, normalize(first), normalize(Enum.join(rest, " ")))
    end
  end

  defp build(line, nil, nil), do: {:error, line, "no name found"}
  defp build(_line, first, last), do: {:ok, %{first_name: first, last_name: last}}

  defp normalize(nil), do: nil

  defp normalize(value) do
    case value |> String.trim() |> String.replace(~r/\s+/u, " ") do
      "" -> nil
      trimmed -> trimmed
    end
  end
end
