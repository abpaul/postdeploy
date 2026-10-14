defmodule Alplus.Measure.VisitorSalt do
  @moduledoc false

  use GenServer

  alias Alplus.Repo

  @salt_bytes 32
  # Keep today and yesterday. Delete anything older so a hash cannot be
  # rebuilt from a long-lived secret after about 48 hours (Fathom).
  @keep_days 1

  def start_link(_opts), do: GenServer.start_link(__MODULE__, :ok, name: __MODULE__)

  @impl true
  def init(:ok) do
    table = :ets.new(__MODULE__, [:named_table, :public, :set, read_concurrency: true])
    {:ok, table}
  end

  @doc "Returns the 32-byte salt for `day`. Creates one if none exists."
  @spec fetch!(Date.t()) :: binary()
  def fetch!(%Date{} = day) do
    case :ets.lookup(__MODULE__, day) do
      [{^day, salt}] -> salt
      [] -> load_or_create!(day)
    end
  end

  @doc "Deletes salts older than yesterday (relative to `today`) from Postgres and ETS."
  @spec prune(Date.t()) :: non_neg_integer()
  def prune(%Date{} = today) do
    cutoff = Date.add(today, -@keep_days)

    {:ok, deleted} =
      Repo.transaction(fn ->
        Repo.query!("DELETE FROM measure_visitor_seen WHERE day < $1", [cutoff])

        %{num_rows: deleted} =
          Repo.query!("DELETE FROM measure_visitor_salts WHERE day < $1", [cutoff])

        deleted
      end)

    Enum.each(:ets.tab2list(__MODULE__), fn
      {day, _salt} ->
        if Date.compare(day, cutoff) == :lt, do: :ets.delete(__MODULE__, day)

      _other ->
        :ok
    end)

    deleted
  end

  defp load_or_create!(day) do
    candidate = :crypto.strong_rand_bytes(@salt_bytes)

    Repo.query!(
      """
      INSERT INTO measure_visitor_salts (day, salt, inserted_at)
      VALUES ($1, $2, now())
      ON CONFLICT (day) DO NOTHING
      """,
      [day, candidate]
    )

    %{rows: [[salt]]} =
      Repo.query!("SELECT salt FROM measure_visitor_salts WHERE day = $1", [day])

    true = :ets.insert(__MODULE__, {day, salt})
    salt
  end
end
