defmodule WeddingPlanner.Transfer.Codec do
  @moduledoc """
  Per-field encoding of transferred rows to JSON values and back (`DR-96`).

  The codec is driven by the schema: a field is encoded by its Ecto type,
  `schema.__schema__(:type, field)`, and enums by `Ecto.Enum.mappings/2`. The table:

  | Ecto type                         | JSON                                         |
  |-----------------------------------|----------------------------------------------|
  | `:id`, `:integer`                 | integer                                      |
  | `:string`                         | string                                       |
  | `:boolean`                        | `true` / `false`                             |
  | `:date`                           | `"YYYY-MM-DD"` (`NFR-20`)                    |
  | `:utc_datetime`                   | `"YYYY-MM-DDTHH:MM:SSZ"` (`NFR-21`)          |
  | `Ecto.Enum`                       | its dumped string                            |
  | `{:array, Ecto.Enum}`             | array of dumped strings                      |
  | `{:array, :integer}` / `:string`  | array of integers / strings                  |
  | `Money.Ecto.Map.Type`             | `{"amount": "7641.50", "currency": "EUR"}`   |
  | any value `nil`                   | `null`                                       |

  Any other type raises `ArgumentError` naming the schema and field, at encode and decode
  time alike, and fails the type tripwire (`supported?/1`).

  ## Money (`NFR-10`, `NFR-12`, `NFR-15`, `DR-18`)

  The amount is `Decimal.to_string(amount, :normal)` at full precision, so
  `7641.4999999999999999` survives. It is decoded with `Decimal.parse/1`, which must consume
  the whole string, and built with `WeddingPlanner.Money.new/2` from the `Decimal`. Never
  from the string: under `nl-BE`, `Money.new(:EUR, "7641.50")` is 764 150. The currency must
  be exactly `"EUR"`.

  ## Strict decoding (`DR-96`)

  A value decodes only if it is exactly what the encoder writes: the right JSON type
  (`"12"` is not 12), a known enum value (looked up in the mapping, never
  `String.to_atom/1`), and the canonical text of a date, datetime or amount (re-encoding
  the decoded value gives back the same string, so `"2026-9-5"`, a `+02:00` offset,
  fractional seconds, `"+5"` or `"1e3"` are refused). `decode/3` returns
  `{:error, phrase}`, where `phrase` completes a sentence after the field's location
  ("must be a whole number"); `WeddingPlanner.Transfer.Document` adds the location.
  """

  @type kind ::
          :integer
          | :string
          | :boolean
          | :date
          | :utc_datetime
          | :money
          | {:array, :integer}
          | {:array, :string}
          | {:enum, keyword()}
          | {:enum_array, keyword()}

  @currency "EUR"

  @doc """
  Whether the codec can carry `{schema, field}` (the type tripwire, `DR-96` (iii)).

  It takes the schema and field rather than the bare Ecto type because an `Ecto.Enum` is
  recognised through `Ecto.Enum.mappings/2`, never by matching its internal type tuple.
  """
  @spec supported?({module(), atom()}) :: boolean()
  def supported?({schema, field}), do: match?({:ok, _}, kind(schema, field))

  @doc """
  The codec kind of `field` in `schema`, or `:error` for a type the codec doesn't support.
  """
  @spec kind(module(), atom()) :: {:ok, kind()} | :error
  def kind(schema, field) do
    type = schema.__schema__(:type, field)

    case enum_mappings(schema, field) do
      {:ok, mappings} ->
        case type do
          {:array, _} -> {:ok, {:enum_array, mappings}}
          _ -> {:ok, {:enum, mappings}}
        end

      :error ->
        base_kind(type)
    end
  end

  @doc """
  The JSON value for `value` of `schema.field` (see the moduledoc's table). Raises
  `ArgumentError` for an unsupported type.
  """
  @spec encode(module(), atom(), term()) :: term()
  def encode(schema, field, value) do
    do_encode(kind!(schema, field), value)
  end

  @doc """
  Decodes `json` (as produced by `Jason.decode/1`) into the typed value of `schema.field`,
  strictly (see the moduledoc). Raises `ArgumentError` for an unsupported type.
  """
  @spec decode(module(), atom(), term()) :: {:ok, term()} | {:error, String.t()}
  def decode(schema, field, json) do
    do_decode(kind!(schema, field), json)
  end

  @doc """
  `decode/3` for a codec `kind` directly, for values that aren't a schema field (the
  document header's `exported_at`, for one).
  """
  @spec decode_kind(kind(), term()) :: {:ok, term()} | {:error, String.t()}
  def decode_kind(kind, json), do: do_decode(kind, json)

  # -- kinds -------------------------------------------------------------------------------

  defp kind!(schema, field) do
    case kind(schema, field) do
      {:ok, kind} ->
        kind

      :error ->
        raise ArgumentError,
              "the transfer codec does not support #{inspect(schema)}.#{field} " <>
                "(type #{inspect(schema.__schema__(:type, field))}); add it to " <>
                "WeddingPlanner.Transfer.Codec (DR-96)"
    end
  end

  defp enum_mappings(schema, field) do
    {:ok, Ecto.Enum.mappings(schema, field)}
  rescue
    ArgumentError -> :error
  end

  defp base_kind(type) when type in [:id, :integer], do: {:ok, :integer}
  defp base_kind(:string), do: {:ok, :string}
  defp base_kind(:boolean), do: {:ok, :boolean}
  defp base_kind(:date), do: {:ok, :date}
  defp base_kind(:utc_datetime), do: {:ok, :utc_datetime}
  defp base_kind({:array, :integer}), do: {:ok, {:array, :integer}}
  defp base_kind({:array, :string}), do: {:ok, {:array, :string}}
  defp base_kind(Money.Ecto.Map.Type), do: {:ok, :money}
  defp base_kind({:parameterized, {Money.Ecto.Map.Type, _params}}), do: {:ok, :money}
  defp base_kind({:parameterized, Money.Ecto.Map.Type, _params}), do: {:ok, :money}
  defp base_kind(_type), do: :error

  # -- encode ------------------------------------------------------------------------------

  defp do_encode(_kind, nil), do: nil
  defp do_encode(:integer, value) when is_integer(value), do: value
  defp do_encode(:string, value) when is_binary(value), do: value
  defp do_encode(:boolean, value) when is_boolean(value), do: value
  defp do_encode(:date, %Date{} = date), do: Date.to_iso8601(date)

  defp do_encode(:utc_datetime, %DateTime{} = datetime) do
    datetime |> DateTime.truncate(:second) |> DateTime.to_iso8601()
  end

  defp do_encode({:array, :integer}, list) when is_list(list), do: list
  defp do_encode({:array, :string}, list) when is_list(list), do: list

  defp do_encode({:enum, mappings}, atom) when is_atom(atom), do: Keyword.fetch!(mappings, atom)

  defp do_encode({:enum_array, mappings}, list) when is_list(list),
    do: Enum.map(list, &Keyword.fetch!(mappings, &1))

  defp do_encode(:money, %Money{currency: :EUR, amount: %Decimal{} = amount}) do
    %{"amount" => Decimal.to_string(amount, :normal), "currency" => @currency}
  end

  # -- decode ------------------------------------------------------------------------------

  defp do_decode(_kind, nil), do: {:ok, nil}

  defp do_decode(:integer, value) when is_integer(value), do: {:ok, value}
  defp do_decode(:integer, _value), do: {:error, "must be a whole number"}

  defp do_decode(:string, value) when is_binary(value), do: {:ok, value}
  defp do_decode(:string, _value), do: {:error, "must be text"}

  defp do_decode(:boolean, value) when is_boolean(value), do: {:ok, value}
  defp do_decode(:boolean, _value), do: {:error, "must be true or false"}

  defp do_decode(:date, value) when is_binary(value) do
    with {:ok, date} <- Date.from_iso8601(value),
         true <- Date.to_iso8601(date) == value do
      {:ok, date}
    else
      _ -> {:error, "must be a date written YYYY-MM-DD, not #{inspect(value)}"}
    end
  end

  defp do_decode(:date, _value), do: {:error, "must be a date written YYYY-MM-DD"}

  defp do_decode(:utc_datetime, value) when is_binary(value) do
    with {:ok, datetime, 0} <- DateTime.from_iso8601(value),
         {0, 0} <- datetime.microsecond,
         true <- DateTime.to_iso8601(datetime) == value do
      {:ok, datetime}
    else
      _ ->
        {:error,
         "must be a UTC time written YYYY-MM-DDTHH:MM:SSZ (whole seconds, ending in Z), " <>
           "not #{inspect(value)}"}
    end
  end

  defp do_decode(:utc_datetime, _value),
    do: {:error, "must be a UTC time written YYYY-MM-DDTHH:MM:SSZ"}

  defp do_decode({:array, :integer}, list) when is_list(list) do
    if Enum.all?(list, &is_integer/1),
      do: {:ok, list},
      else: {:error, "must be a list of whole numbers"}
  end

  defp do_decode({:array, :integer}, _value), do: {:error, "must be a list of whole numbers"}

  defp do_decode({:array, :string}, list) when is_list(list) do
    if Enum.all?(list, &is_binary/1),
      do: {:ok, list},
      else: {:error, "must be a list of texts"}
  end

  defp do_decode({:array, :string}, _value), do: {:error, "must be a list of texts"}

  defp do_decode({:enum, mappings}, value), do: decode_enum_value(mappings, value)

  defp do_decode({:enum_array, mappings}, list) when is_list(list) do
    Enum.reduce_while(list, {:ok, []}, fn value, {:ok, acc} ->
      case decode_enum_value(mappings, value) do
        {:ok, atom} -> {:cont, {:ok, [atom | acc]}}
        {:error, _} = error -> {:halt, error}
      end
    end)
    |> case do
      {:ok, atoms} -> {:ok, Enum.reverse(atoms)}
      error -> error
    end
  end

  defp do_decode({:enum_array, _mappings}, _value), do: {:error, "must be a list"}

  defp do_decode(:money, %{} = object) do
    case Enum.sort(Map.keys(object)) do
      ["amount", "currency"] -> decode_money(object["amount"], object["currency"])
      _ -> {:error, money_shape_error()}
    end
  end

  defp do_decode(:money, _value), do: {:error, money_shape_error()}

  defp decode_enum_value(mappings, value) do
    case Enum.find(mappings, fn {_atom, dumped} -> dumped === value end) do
      {atom, _dumped} -> {:ok, atom}
      nil -> {:error, "has an unknown value #{inspect(value)}"}
    end
  end

  defp decode_money(amount, @currency) when is_binary(amount) do
    with {%Decimal{} = decimal, ""} <- Decimal.parse(amount),
         false <- Decimal.nan?(decimal) or Decimal.inf?(decimal),
         true <- Decimal.to_string(decimal, :normal) == amount do
      {:ok, WeddingPlanner.Money.new(decimal, :EUR)}
    else
      _ -> {:error, "has an amount that isn't a plain decimal number: #{inspect(amount)}"}
    end
  end

  defp decode_money(amount, currency) when is_binary(amount),
    do: {:error, "has the currency #{inspect(currency)}; only \"EUR\" is allowed"}

  defp decode_money(_amount, _currency), do: {:error, money_shape_error()}

  defp money_shape_error,
    do: ~s(must be an amount written {"amount": "12.50", "currency": "EUR"})
end
