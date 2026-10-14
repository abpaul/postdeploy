defmodule Alplus.Repo.Migrations.AddMeasureSourceHostname do
  @moduledoc """
  Stores the origin represented by a Measure Source.

  A display name is editable and cannot identify a domain. Existing Measure
  Sources whose names are already hostname-shaped retain that value. Other
  existing Sources remain uninstalled until an explicit domain is configured;
  new sites always write the normalized allowlist hostname.
  """

  use Ecto.Migration

  def up do
    alter table(:sources) do
      add :hostname, :text
    end

    execute("""
    UPDATE sources
    SET hostname = lower(btrim(name))
    WHERE type = 'measure'
      AND hostname IS NULL
      AND octet_length(btrim(name)) BETWEEN 1 AND 255
      AND (
        lower(btrim(name)) ~ '^[a-z0-9]([a-z0-9-]*[a-z0-9])?([.][a-z0-9]([a-z0-9-]*[a-z0-9])?)*$'
        OR lower(btrim(name)) ~ '^\\*[.][a-z0-9]([a-z0-9-]*[a-z0-9])?([.][a-z0-9]([a-z0-9-]*[a-z0-9])?)+$'
      )
    """)

    execute("""
    ALTER TABLE sources
      ADD CONSTRAINT sources_hostname_check CHECK (
        hostname IS NULL OR (
          hostname = lower(btrim(hostname)) AND
            octet_length(btrim(hostname)) BETWEEN 1 AND 255 AND (
            lower(btrim(hostname)) ~ '^[a-z0-9]([a-z0-9-]*[a-z0-9])?([.][a-z0-9]([a-z0-9-]*[a-z0-9])?)*$'
            OR lower(btrim(hostname)) ~ '^\\*[.][a-z0-9]([a-z0-9-]*[a-z0-9])?([.][a-z0-9]([a-z0-9-]*[a-z0-9])?)+$'
          )
        )
      )
    """)
  end

  def down do
    execute("ALTER TABLE sources DROP CONSTRAINT IF EXISTS sources_hostname_check")

    alter table(:sources) do
      remove :hostname
    end
  end
end
