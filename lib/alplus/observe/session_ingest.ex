defmodule Alplus.Observe.SessionIngest do
  @moduledoc "Domain boundary for authenticated crash-free session ingestion."

  alias Alplus.Observe.SessionRollupWriter

  @doc "Persists session outcomes and returns accepted and dropped counts."
  @spec write(map(), map()) :: %{
          accepted: non_neg_integer(),
          dropped: non_neg_integer(),
          dropped_reason: String.t() | nil
        }

  def write(envelope, %{source: source, environment: environment, malformed: malformed})
      when is_map(envelope) and is_map(source) and is_integer(malformed) and malformed >= 0 do
    received_at = DateTime.utc_now()

    outcome =
      Enum.reduce(envelope.items, %{accepted: 0, duplicates: 0}, fn item, acc ->
        session = %{
          session_id: item["id"],
          org_id: source.org_id,
          project_id: source.project_id,
          source_id: source.id,
          environment: environment,
          status: item["status"],
          release: item["release"],
          received_at: received_at
        }

        case SessionRollupWriter.record!(session) do
          :claimed -> %{acc | accepted: acc.accepted + 1}
          :duplicate -> %{acc | duplicates: acc.duplicates + 1}
        end
      end)

    dropped = malformed + outcome.duplicates

    dropped_reason =
      cond do
        dropped == 0 -> nil
        malformed > 0 and outcome.duplicates == 0 -> "malformed"
        malformed == 0 and outcome.duplicates > 0 -> "duplicate"
        true -> "mixed"
      end

    %{accepted: outcome.accepted, dropped: dropped, dropped_reason: dropped_reason}
  end
end
