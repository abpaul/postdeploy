defmodule Alplus.Mcp.Error do
  @moduledoc "Stable, redacted domain errors for the MCP boundary."

  @enforce_keys [:code, :message, :details]
  defstruct [:code, :message, :details]

  @type t :: %__MODULE__{code: atom(), message: String.t(), details: map()}

  @spec new(atom(), String.t(), map()) :: t()
  def new(code, message, details \\ %{})
      when is_atom(code) and is_binary(message) and is_map(details) do
    %__MODULE__{code: code, message: message, details: details}
  end

  @spec from(term()) :: t()
  def from(%__MODULE__{} = error), do: error
  def from({:error, %__MODULE__{} = error}), do: error
  def from(:not_found), do: new(:not_found, "The requested resource was not found", %{})
  def from(:forbidden), do: new(:forbidden_role, "The caller cannot perform this action", %{})
  def from(:revoked), do: new(:revoked, "The credential is revoked", %{})
  def from(:cancelled), do: new(:cancelled, "The operation was cancelled", %{})

  def from(:missing_idempotency_key),
    do: new(:missing_idempotency_key, "An idempotency key is required", %{})

  def from(:project_required),
    do:
      new(
        :project_required,
        "Choose a project for this organization connection",
        %{field: "project_ref"}
      )

  def from(:rate_limited), do: new(:rate_limited, "Rate limit exceeded", %{})

  def from({:insufficient_scope, required_scopes}) when is_list(required_scopes) do
    new(
      :insufficient_scope,
      "The caller lacks the required scope",
      %{required_scopes: Enum.filter(required_scopes, &is_binary/1)}
    )
  end

  def from(:invalid_cursor), do: new(:invalid_cursor, "The cursor is invalid", %{})
  def from(:cursor_expired), do: new(:cursor_expired, "The cursor has expired", %{})

  def from({:missing_argument, field}),
    do: new(:invalid_argument, "A required argument is missing", %{field: field})

  def from({:invalid_argument, field}),
    do: new(:invalid_argument, "The argument is invalid", %{field: field})

  def from({:invalid_enum, field, allowed}),
    do: new(:invalid_argument, "The argument is invalid", %{field: field, allowed: allowed})

  def from(%Ash.Error.Forbidden{}), do: from(:forbidden)
  def from(%Ash.Error.Query.NotFound{}), do: from(:not_found)
  def from(%Ash.Error.Invalid{}), do: new(:invalid_argument, "The request is invalid", %{})

  def from(%{code: code, message: message, details: details})
      when is_atom(code) and is_binary(message) and is_map(details),
      do: new(code, message, %{})

  def from(_term), do: new(:invalid_argument, "The request is invalid", %{})
end
