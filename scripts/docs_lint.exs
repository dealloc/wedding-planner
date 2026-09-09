# Lints the stable rule IDs that `docs/README.md` declares as referenceable from plans,
# tickets, tests and commits.
#
#     elixir scripts/docs_lint.exs
#
# Reports duplicate definitions, definitions that appear out of order within a file, and
# references to IDs that are never defined. Numbering gaps are listed for information
# only: `docs/README.md` states the numbering within a prefix need not be contiguous.

defmodule DocsLint do
  # A rule is defined by a bold list item (`- **PER-01** …`) or, for decisions, by being
  # the first cell of a table row (`| D-09 | … |`).
  @defined_list ~r/^\s*-\s+\*\*([A-Z]{2,4}-\d{2})\b/
  @defined_table ~r/^\|\s*([A-Z]{2,4}-\d{2})\s*\|/
  @reference ~r/\b([A-Z]{2,4}-\d{2})\b/

  def run(root) do
    files =
      Path.wildcard(Path.join(root, "docs/**/*.md")) ++
        [Path.join(root, "README.md"), Path.join(root, "AGENTS.md")]

    files = Enum.filter(files, &File.exists?/1)
    definitions = Enum.flat_map(files, &definitions_in(root, &1))
    references = Enum.flat_map(files, &references_in(root, &1))

    defined_ids = MapSet.new(definitions, & &1.id)

    problems =
      duplicates(definitions) ++ out_of_order(definitions) ++ dangling(references, defined_ids)

    Enum.each(problems, &IO.puts/1)
    report_gaps(defined_ids)

    IO.puts("\n#{MapSet.size(defined_ids)} rule IDs defined across #{length(files)} files.")

    case problems do
      [] -> IO.puts("No problems found.")
      _ -> System.halt(1)
    end
  end

  defp definitions_in(root, path) do
    rel = Path.relative_to(path, root)

    path
    |> File.read!()
    |> String.split("\n")
    |> Enum.with_index(1)
    |> Enum.map_reduce("(top)", fn {line, no}, section ->
      section = if String.starts_with?(line, "#"), do: String.trim(line), else: section

      case Regex.run(@defined_list, line) || Regex.run(@defined_table, line) do
        [_, id] -> {[%{id: id, file: rel, line: no, section: section}], section}
        nil -> {[], section}
      end
    end)
    |> elem(0)
    |> List.flatten()
  end

  defp references_in(root, path) do
    scan(root, path, fn line, rel, no ->
      @reference
      |> Regex.scan(line)
      |> Enum.map(fn [_, id] -> %{id: id, file: rel, line: no} end)
    end)
  end

  defp scan(root, path, fun) do
    rel = Path.relative_to(path, root)

    path
    |> File.read!()
    |> String.split("\n")
    |> Enum.with_index(1)
    |> Enum.flat_map(fn {line, no} -> fun.(line, rel, no) end)
  end

  defp duplicates(definitions) do
    definitions
    |> Enum.group_by(& &1.id)
    |> Enum.filter(fn {_id, defs} -> length(defs) > 1 end)
    |> Enum.sort()
    |> Enum.map(fn {id, defs} ->
      where = Enum.map_join(defs, ", ", &"#{&1.file}:#{&1.line}")
      "DUPLICATE  #{id} defined #{length(defs)} times: #{where}"
    end)
  end

  # Within one section of one file, definitions should read in ascending order. The check
  # is per-section rather than per-file on purpose: `offers-and-comparison.md` puts
  # Confirmation (CST-40…) after Comparison matrix (CST-50…), which is deliberate.
  defp out_of_order(definitions) do
    definitions
    |> Enum.group_by(fn d -> {d.file, d.section, prefix(d.id)} end)
    |> Enum.sort()
    |> Enum.flat_map(fn {{file, _section, prefix}, defs} ->
      defs
      |> Enum.sort_by(& &1.line)
      |> Enum.chunk_every(2, 1, :discard)
      |> Enum.filter(fn [a, b] -> number(b.id) < number(a.id) end)
      |> Enum.map(fn [a, b] ->
        "ORDER      #{file}: #{prefix} runs backwards — #{b.id} (line #{b.line}) " <>
          "follows #{a.id} (line #{a.line})"
      end)
    end)
  end

  defp dangling(references, defined_ids) do
    references
    |> Enum.reject(&MapSet.member?(defined_ids, &1.id))
    |> Enum.group_by(& &1.id)
    |> Enum.sort()
    |> Enum.map(fn {id, refs} ->
      where = Enum.map_join(Enum.take(refs, 4), ", ", &"#{&1.file}:#{&1.line}")
      "UNDEFINED  #{id} is referenced but never defined: #{where}"
    end)
  end

  defp report_gaps(defined_ids) do
    defined_ids
    |> Enum.group_by(&prefix/1, &number/1)
    |> Enum.sort()
    |> Enum.each(fn {prefix, numbers} ->
      numbers = Enum.sort(numbers)
      gaps = Enum.to_list(Enum.min(numbers)..Enum.max(numbers)) -- numbers

      if gaps != [] do
        IO.puts("gap (ok)   #{prefix}: unused #{Enum.map_join(gaps, ", ", &pad/1)}")
      end
    end)
  end

  defp prefix(id), do: id |> String.split("-") |> hd()
  defp number(id), do: id |> String.split("-") |> List.last() |> String.to_integer()
  defp pad(n), do: String.pad_leading(Integer.to_string(n), 2, "0")
end

DocsLint.run(Path.expand(Path.join(__DIR__, "..")))
