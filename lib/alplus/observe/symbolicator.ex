defmodule Alplus.Observe.Symbolicator do
  @moduledoc """
  Remaps minified JS frames to original source positions at ingest, using
  the release's uploaded source maps (`Alplus.Observe.ReleaseArtifact`).

  Runs BEFORE fingerprinting on purpose: minified function names and
  positions differ per build, so grouping on raw frames would split one
  issue across releases.

  Tenancy: artifacts resolve strictly by the ingesting Source's org,
  project, and the named release version. There is no cross-project map
  lookup.

  Fail-open per frame: a frame with no matching artifact, an unparsable
  map, or a position the map does not cover passes through unchanged. A
  dropped event would be strictly worse than a minified frame.

  Decoded maps cache in a bounded public ETS table (`start_link/1` owns
  it, supervised in `Alplus.Application`), keyed by the artifact's sha256,
  so an error burst decodes each map once, not once per event.
  """

  use GenServer

  alias Alplus.Observe.{PayloadStore, SourceMap}
  alias Alplus.Repo

  @table __MODULE__
  @max_cached_maps 64
  @context_lines 3
  # Frames come from `error_envelope.ex`-validated items, so these are the
  # only keys a frame can carry going in.
  @sourcemap_suffix ".map"

  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @impl true
  def init(_opts) do
    :ets.new(@table, [:named_table, :public, :set, read_concurrency: true])
    {:ok, %{}}
  end

  @doc """
  Remaps every frame it can; returns the frame list with the same length
  and order. `source` is the authenticated ingest Source; `release` the
  item's release string (version). A nil release or a release with no
  artifacts returns the frames unchanged.
  """
  @spec symbolicate(
          [map()] | nil,
          %{id: String.t(), org_id: String.t(), project_id: String.t()},
          String.t() | nil
        ) ::
          [map()] | nil
  def symbolicate(frames, _source, nil), do: frames
  def symbolicate(nil, _source, _release), do: nil

  def symbolicate(frames, source, release) when is_list(frames) do
    case artifact_index(source, release) do
      empty when map_size(empty) == 0 -> frames
      index -> Enum.map(frames, &symbolicate_frame(&1, index))
    end
  rescue
    # A symbolication crash must never fail ingest.
    _ -> frames
  end

  # name => %{storage_key, sha256}, for this org+project+release version.
  defp artifact_index(source, release) do
    %{rows: rows} =
      Repo.query!(
        """
        SELECT a.name, a.storage_key, a.sha256
        FROM release_artifacts a
        JOIN releases r ON r.id = a.release_id
        WHERE a.org_id = $1 AND a.project_id = $2
          AND r.source_id = $3 AND r.version = $4 AND a.type = 'source_map'
        """,
        [source.org_id, source.project_id, source.id, release]
      )

    Map.new(rows, fn [name, storage_key, sha256] ->
      {name, %{storage_key: storage_key, sha256: sha256}}
    end)
  end

  defp symbolicate_frame(frame, index) do
    with file when is_binary(file) <- frame[:file],
         lineno when is_integer(lineno) and lineno >= 1 <- frame[:lineno],
         colno when is_integer(colno) and colno >= 1 <- frame[:colno],
         {:ok, artifact} <- match_artifact(index, file),
         {:ok, parsed} <- cached_map(artifact),
         {:ok, position} <- SourceMap.lookup(parsed, lineno, colno) do
      remap_frame(frame, parsed, position)
    else
      _ -> frame
    end
  end

  # An artifact uploaded as "app-abc123.js.map" matches the frame file
  # ".../app-abc123.js" (any origin/path). The basename convention keeps
  # uploads independent of the exact URL the asset was served from.
  defp match_artifact(index, file) do
    basename = file |> String.split(["#", "?"], parts: 2) |> hd() |> Path.basename()

    case Map.fetch(index, basename <> @sourcemap_suffix) do
      {:ok, artifact} -> {:ok, artifact}
      :error -> :error
    end
  end

  defp cached_map(%{storage_key: storage_key, sha256: sha256}) do
    case :ets.lookup(@table, sha256) do
      [{^sha256, parsed}] ->
        {:ok, parsed}

      [] ->
        with {:ok, raw} <- PayloadStore.fetch_raw(storage_key),
             {:ok, parsed} <- SourceMap.parse(raw) do
          cache_put(sha256, parsed)
          {:ok, parsed}
        end
    end
  end

  defp cache_put(sha256, parsed) do
    if :ets.info(@table, :size) >= @max_cached_maps do
      # Bounded, coarse eviction: drop the whole table rather than track
      # LRU order. 64 decoded maps is already far past one deploy's set.
      :ets.delete_all_objects(@table)
    end

    :ets.insert(@table, {sha256, parsed})
  end

  defp remap_frame(frame, parsed, position) do
    context =
      case SourceMap.source_context(parsed, position.source, position.line, @context_lines) do
        {:ok, context} -> context
        :error -> %{}
      end

    frame
    |> Map.merge(%{
      file: position.source || frame[:file],
      lineno: position.line,
      colno: position.column,
      function: position.name || frame[:function],
      in_app: in_app?(position.source)
    })
    |> Map.merge(context)
  end

  # Original paths look like "webpack://app/src/checkout.ts" or
  # "../src/lib.ts"; vendored code keeps its node_modules segment.
  defp in_app?(nil), do: false
  defp in_app?(source), do: not String.contains?(source, "node_modules")
end
