defmodule Alplus.Monitoring.ExpiryScanner do
  @moduledoc """
  Boundary for the SSL certificate and domain-registration lookups.

  `ExpiryScan` accepts an implementation explicitly. Tests therefore never
  open sockets, and the maintenance job has one small, replaceable outbound
  boundary with an explicit timeout.
  """

  @type expiry_result :: %{
          optional(:ssl_expires_at) => DateTime.t() | nil,
          optional(:domain_expires_at) => DateTime.t() | nil
        }

  @callback scan(String.t(), keyword()) :: {:ok, expiry_result()} | {:error, term()}
end
