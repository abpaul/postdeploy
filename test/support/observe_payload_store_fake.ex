defmodule Alplus.Observe.PayloadStore.Fake do
  @moduledoc false

  @behaviour Alplus.Observe.PayloadStore

  @impl true
  def put(key, payload) do
    case Application.get_env(:alplus, :observe_payload_store_test_pid) do
      pid when is_pid(pid) ->
        send(pid, {:observe_payload_stored, key, payload})

        case Application.get_env(:alplus, :observe_payload_store_test_put_hook) do
          hook when is_function(hook, 2) -> hook.(key, payload)
          _ -> :ok
        end

        :ok

      _ ->
        {:error, :missing_test_recipient}
    end
  end

  # Tests configure a get response per key via `:observe_payload_store_test_gets`,
  # a map of key => `{:ok, binary}` | `{:error, reason}`.
  @impl true
  def get(key) do
    responses = Application.get_env(:alplus, :observe_payload_store_test_gets, %{})

    case Map.fetch(responses, key) do
      {:ok, response} -> response
      :error -> {:error, :not_found}
    end
  end

  @impl true
  def delete(key) do
    response =
      Application.get_env(:alplus, :observe_payload_store_test_deletes, %{})
      |> Map.get(key, :ok)

    if response == :ok do
      case Application.get_env(:alplus, :observe_payload_store_test_pid) do
        pid when is_pid(pid) -> send(pid, {:observe_payload_deleted, key})
        _ -> :ok
      end
    end

    response
  end
end
