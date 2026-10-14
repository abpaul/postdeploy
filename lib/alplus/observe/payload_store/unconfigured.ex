defmodule Alplus.Observe.PayloadStore.Unconfigured do
  @moduledoc false

  @behaviour Alplus.Observe.PayloadStore

  @impl true
  def put(_key, _payload), do: {:error, :payload_store_unconfigured}

  @impl true
  def get(_key), do: {:error, :payload_store_unconfigured}

  @impl true
  def delete(_key), do: {:error, :payload_store_unconfigured}
end
