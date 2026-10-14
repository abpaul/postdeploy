defmodule Alplus.LoadTest.Adapter do
  @moduledoc false

  @callback request(String.t(), String.t()) ::
              {:ok, non_neg_integer()} | {:error, term()}
end
