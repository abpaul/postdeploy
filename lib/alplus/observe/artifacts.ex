defmodule Alplus.Observe.Artifacts do
  @moduledoc "Domain boundary for authenticated source-map storage and replacement."

  require Ash.Query

  alias Alplus.Observe.PayloadStore

  @max_name_bytes 512
  @max_release_bytes 200

  @doc "Validates and stores one source map for the authenticated source."
  @spec ingest(map(), String.t(), String.t(), binary()) ::
          {:ok, map()} | {:error, :invalid_params | :invalid_source_map | {:store_failed, term()}}
  def ingest(source, release, name, raw) when is_map(source) and is_binary(raw) do
    with {:ok, release, name} <- validate_params(release, name),
         :ok <- validate_source_map(raw),
         {:ok, artifact} <- store(source, release, name, raw) do
      {:ok, artifact}
    else
      :invalid_params -> {:error, :invalid_params}
      :invalid_source_map -> {:error, :invalid_source_map}
      {:store_failed, reason} -> {:error, {:store_failed, reason}}
    end
  end

  def ingest(_source, _release, _name, _raw), do: {:error, :invalid_params}

  defp validate_params(release, name) when is_binary(release) and is_binary(name) do
    release = String.trim(release)
    name = String.trim(name)

    if byte_size(release) in 1..@max_release_bytes and byte_size(name) in 1..@max_name_bytes and
         String.ends_with?(name, ".map") and not String.contains?(name, ["/", "\\", ".."]) do
      {:ok, release, name}
    else
      :invalid_params
    end
  end

  defp validate_params(_release, _name), do: :invalid_params

  defp validate_source_map(raw) do
    case Jason.decode(raw) do
      {:ok, %{"version" => 3, "mappings" => mappings, "sources" => sources}}
      when is_binary(mappings) and is_list(sources) ->
        :ok

      _ ->
        :invalid_source_map
    end
  end

  defp store(source, release_version, name, raw) do
    release = find_or_create_release(source, release_version)
    storage_key = "artifacts/#{source.project_id}/#{release.id}/#{name}"

    case PayloadStore.store_raw(storage_key, raw) do
      :ok -> upsert_artifact(source, release, name, storage_key, raw)
      {:error, reason} -> {:store_failed, reason}
    end
  rescue
    error -> {:store_failed, error}
  end

  defp find_or_create_release(source, version) do
    Alplus.Observe.Release
    |> Ash.Query.filter(
      org_id == ^source.org_id and project_id == ^source.project_id and
        source_id == ^source.id and version == ^version
    )
    |> Ash.read!(authorize?: false)
    |> case do
      [release | _] ->
        release

      [] ->
        Ash.create!(
          Alplus.Observe.Release,
          %{
            org_id: source.org_id,
            project_id: source.project_id,
            source_id: source.id,
            environment: source.environment,
            version: version,
            released_at: DateTime.utc_now()
          },
          authorize?: false
        )
    end
  end

  defp upsert_artifact(source, release, name, storage_key, raw) do
    sha256 = :crypto.hash(:sha256, raw) |> Base.encode16(case: :lower)

    existing =
      Alplus.Observe.ReleaseArtifact
      |> Ash.Query.filter(release_id == ^release.id and name == ^name)
      |> Ash.read!(authorize?: false)

    Enum.each(existing, &Ash.destroy!(&1, authorize?: false))

    artifact =
      Ash.create!(
        Alplus.Observe.ReleaseArtifact,
        %{
          org_id: source.org_id,
          project_id: source.project_id,
          release_id: release.id,
          name: name,
          type: "source_map",
          storage_key: storage_key,
          sha256: sha256,
          byte_size: byte_size(raw)
        },
        authorize?: false
      )

    {:ok, artifact}
  rescue
    error -> {:store_failed, error}
  end
end
