defmodule Alplus.Mcp.Args do
  @moduledoc """
  Reads and validates MCP tool arguments.

  Callers send arguments with string keys. Internal callers and tests send atom
  keys. Every function accepts both.
  """

  @doc "Reads one argument by its string key, then by the matching atom key."
  @spec value(map(), String.t()) :: term()
  def value(args, key) when is_map(args) and is_binary(key) do
    case Map.fetch(args, key) do
      {:ok, value} -> value
      :error -> Map.get(args, atom_key(key))
    end
  end

  @doc "Returns a non-empty string argument."
  @spec required_string(map(), String.t()) ::
          {:ok, String.t()} | {:error, {:missing_argument, String.t()}}
  def required_string(args, key) do
    case value(args, key) do
      value when is_binary(value) and byte_size(value) > 0 -> {:ok, value}
      _ -> {:error, {:missing_argument, key}}
    end
  end

  @doc "Returns a non-empty string argument, or nil when the argument is absent."
  @spec optional_string(map(), String.t()) ::
          {:ok, String.t() | nil} | {:error, {:invalid_argument, String.t()}}
  def optional_string(args, key) do
    case value(args, key) do
      nil -> {:ok, nil}
      value when is_binary(value) and byte_size(value) > 0 -> {:ok, value}
      _ -> {:error, {:invalid_argument, key}}
    end
  end

  @doc "Returns a string argument that must be one of the allowed values."
  @spec required_enum(map(), String.t(), [String.t()]) ::
          {:ok, String.t()} | {:error, {:invalid_enum, String.t(), [String.t()]}}
  def required_enum(args, key, allowed) do
    case value(args, key) do
      value when is_binary(value) -> member(value, key, allowed)
      _ -> {:error, {:invalid_enum, key, allowed}}
    end
  end

  @doc "Returns an allowed string argument, or nil when the argument is absent."
  @spec optional_enum(map(), String.t(), [String.t()]) ::
          {:ok, String.t() | nil} | {:error, {:invalid_enum, String.t(), [String.t()]}}
  def optional_enum(args, key, allowed) do
    case value(args, key) do
      nil -> {:ok, nil}
      value when is_binary(value) -> member(value, key, allowed)
      _ -> {:error, {:invalid_enum, key, allowed}}
    end
  end

  @doc """
  Returns an integer argument inside the given range.

  Accepts an integer or a decimal string. Returns `default` when the argument is
  absent, and `{:error, error}` for every other input.
  """
  @spec bounded_integer(map(), String.t(), integer(), integer(), term(), term()) ::
          {:ok, integer()} | {:error, term()}
  def bounded_integer(args, key, minimum, maximum, default, error) do
    case value(args, key) do
      nil ->
        {:ok, default}

      value when is_integer(value) ->
        in_range(value, minimum, maximum, error)

      value when is_binary(value) ->
        case Integer.parse(value) do
          {parsed, ""} -> in_range(parsed, minimum, maximum, error)
          _ -> {:error, error}
        end

      _ ->
        {:error, error}
    end
  end

  @doc "Redacts an offending argument so it is safe to return in error details."
  @spec detail_value(term()) :: term()
  def detail_value(value)
      when is_integer(value) or is_float(value) or is_boolean(value) or is_nil(value),
      do: value

  def detail_value(value) when is_binary(value), do: String.slice(value, 0, 64)
  def detail_value(_value), do: "unsupported_type"

  defp member(value, key, allowed) do
    if value in allowed, do: {:ok, value}, else: {:error, {:invalid_enum, key, allowed}}
  end

  defp in_range(value, minimum, maximum, error) do
    if value >= minimum and value <= maximum, do: {:ok, value}, else: {:error, error}
  end

  defp atom_key(key) do
    String.to_existing_atom(key)
  rescue
    ArgumentError -> nil
  end
end
