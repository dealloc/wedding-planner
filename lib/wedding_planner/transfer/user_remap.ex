defmodule WeddingPlanner.Transfer.UserRemap do
  @moduledoc """
  Matches the users an import file names to this installation's users (`DR-93` (2)).

  Users never travel: the file carries only an `id` + `display_name` list, and the rows'
  user fields (`WeddingPlanner.Transfer.Tables.user_references/0`: task owners and
  activity-entry authors) point into it. On import each **referenced** file user is
  matched to a target by display name, trimmed and case-folded:

    * the targets are the **assignable** users (`WeddingPlanner.Accounts.Users.list_assignable/0`,
      users with a passkey, `DR-22`), so a provisional user mid-enrollment is never matched
      and a task is never owned by one;
    * a file user matches a target **iff exactly one** target has the same key;
    * otherwise (no match, or several targets with that key) the file user maps to the
      **importing user** (`scope.user`) and the preview says so (`matched?: false`).

  File users no row refers to are ignored (they appear in neither the map nor the
  preview). Rows are then rewritten through the map for exactly the user-reference fields;
  a `nil` owner stays `nil`.
  """

  alias WeddingPlanner.Accounts.Scope
  alias WeddingPlanner.Accounts.User
  alias WeddingPlanner.Accounts.Users
  alias WeddingPlanner.Transfer.Document
  alias WeddingPlanner.Transfer.Tables

  @type mapping :: %{source_name: String.t(), target_name: String.t(), matched?: boolean()}
  @type t :: %{ids: %{pos_integer() => pos_integer()}, preview: [mapping()]}

  @doc """
  The remap for `document` when `scope`'s user imports it: `ids` maps each referenced file
  user id to a target user id, `preview` lists one mapping per referenced file user, in
  the file's `users` order.
  """
  @spec build(Document.t(), Scope.t()) :: t()
  def build(%Document{} = document, %Scope{user: %User{} = importer}) do
    referenced = referenced_ids(document)
    targets_by_key = Enum.group_by(Users.list_assignable(), &key(&1.display_name))

    pairs =
      for %{id: id, display_name: name} <- document.users, MapSet.member?(referenced, id) do
        case Map.get(targets_by_key, key(name), []) do
          [%User{} = target] ->
            {id, target, %{source_name: name, target_name: target.display_name, matched?: true}}

          _none_or_ambiguous ->
            {id, importer,
             %{source_name: name, target_name: importer.display_name, matched?: false}}
        end
      end

    %{
      ids: Map.new(pairs, fn {id, target, _mapping} -> {id, target.id} end),
      preview: Enum.map(pairs, fn {_id, _target, mapping} -> mapping end)
    }
  end

  @doc "Rewrites every user-reference field of `document`'s rows through `ids`."
  @spec rewrite(Document.t(), %{pos_integer() => pos_integer()}) :: Document.t()
  def rewrite(%Document{tables: tables} = document, ids) do
    fields_by_schema =
      Enum.group_by(Tables.user_references(), &elem(&1, 0), &elem(&1, 1))

    tables =
      Enum.map(tables, fn {%{schema: schema} = entry, rows} ->
        case Map.get(fields_by_schema, schema) do
          nil -> {entry, rows}
          fields -> {entry, Enum.map(rows, &rewrite_row(&1, fields, ids))}
        end
      end)

    %{document | tables: tables}
  end

  defp rewrite_row(row, fields, ids) do
    Enum.reduce(fields, row, fn field, row ->
      case Map.fetch!(row, field) do
        nil -> row
        user_id -> Map.put(row, field, Map.fetch!(ids, user_id))
      end
    end)
  end

  defp referenced_ids(%Document{tables: tables}) do
    for {schema, field} <- Tables.user_references(),
        {%{schema: ^schema}, rows} <- tables,
        row <- rows,
        user_id = Map.fetch!(row, field),
        not is_nil(user_id),
        into: MapSet.new(),
        do: user_id
  end

  defp key(display_name), do: display_name |> String.trim() |> String.downcase()
end
