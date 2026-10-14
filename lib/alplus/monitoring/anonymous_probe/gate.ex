defmodule Alplus.Monitoring.AnonymousProbe.Gate do
  @moduledoc false

  use GenServer

  def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @spec admit(String.t()) :: :ok | {:error, :busy | :journey_busy}
  def admit(journey_id) when is_binary(journey_id) do
    GenServer.call(__MODULE__, {:admit, journey_id})
  end

  @spec release(String.t()) :: :ok
  def release(journey_id) when is_binary(journey_id) do
    GenServer.cast(__MODULE__, {:release, journey_id})
  end

  @impl true
  def init(_opts) do
    max = setting(:max_concurrency, 8)
    {:ok, %{max: max, inflight: %{}}}
  end

  @impl true
  def handle_call({:admit, journey_id}, _from, state) do
    cond do
      Map.has_key?(state.inflight, journey_id) ->
        {:reply, {:error, :journey_busy}, state}

      map_size(state.inflight) >= state.max ->
        {:reply, {:error, :busy}, state}

      true ->
        {:reply, :ok, %{state | inflight: Map.put(state.inflight, journey_id, true)}}
    end
  end

  @impl true
  def handle_cast({:release, journey_id}, state) do
    {:noreply, %{state | inflight: Map.delete(state.inflight, journey_id)}}
  end

  defp setting(key, default) do
    :alplus
    |> Application.get_env(__MODULE__, [])
    |> Keyword.get(key, default)
  end
end
