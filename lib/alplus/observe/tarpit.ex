defmodule Alplus.Observe.Tarpit do
  @moduledoc false

  @spec delay_invalid_key() :: :ok
  def delay_invalid_key do
    {module, function} =
      Application.get_env(:alplus, :observe_invalid_key_tarpit, {__MODULE__, :sleep})

    apply(module, function, [Application.get_env(:alplus, :observe_invalid_key_tarpit_ms, 250)])
  end

  @doc "Default injected delay. Tests replace this function through application config."
  @spec sleep(non_neg_integer()) :: :ok
  def sleep(milliseconds) when is_integer(milliseconds) and milliseconds >= 0 do
    Process.sleep(milliseconds)
    :ok
  end
end
