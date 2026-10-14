defmodule Alplus.Mailer do
  use Swoosh.Mailer, otp_app: :alplus

  @doc """
  The default From address as a `{name, address}` tuple.

  Production sets `:mail_from` from the `MAIL_FROM` env var (a bare address);
  the display name defaults to "PostDeploy". Dev and test fall back to a placeholder,
  since the Local and Test adapters never send real mail.
  """
  @spec from_address() :: {String.t(), String.t()}
  def from_address do
    case Application.fetch_env(:alplus, :mail_from) do
      {:ok, {_name, _address} = tuple} -> tuple
      {:ok, address} when is_binary(address) -> {"PostDeploy", address}
      :error -> {"PostDeploy", "noreply@example.com"}
    end
  end
end
