defmodule Alplus.Repo.Migrations.AddMeasureLandingPageVisits do
  use Ecto.Migration

  # This is the expand phase. It adds a nullable counter without a default,
  # so Postgres does not rewrite existing rows. Historic dimensions remain
  # nil because raw hits cannot safely be reclassified as landing pages.
  # A later contract migration can backfill and enforce `NOT NULL` after
  # production verifies the new writer.
  def up do
    execute("SET lock_timeout = '3s'")

    alter table(:analytics_dimensions) do
      add :visits, :bigint
    end

    execute("ALTER TABLE analytics_dimensions DROP CONSTRAINT analytics_dimensions_shape_check")

    execute("""
    ALTER TABLE analytics_dimensions
      ADD CONSTRAINT analytics_dimensions_shape_check CHECK (
        dimension IN ('path', 'landing_page', 'hostname', 'event', 'referrer', 'country', 'browser') AND
        octet_length(value) BETWEEN 1 AND 512 AND visitors >= 0 AND pageviews >= 0 AND
        (visits IS NULL OR visits >= 0)
      ) NOT VALID
    """)
  end
end
