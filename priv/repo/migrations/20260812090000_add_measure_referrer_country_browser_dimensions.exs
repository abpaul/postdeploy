defmodule Alplus.Repo.Migrations.AddMeasureReferrerCountryBrowserDimensions do
  @moduledoc """
  Widens `analytics_dimensions`' closed-set CHECK to allow the `referrer`,
  `country`, and `browser` dimensions (issue #9), alongside the existing
  `path`/`hostname`/`event`. Forward-only: drop and recreate the
  constraint, matching how it was first added in
  `20260811103000_add_measure_daily_dimension_rollups.exs`.
  """

  use Ecto.Migration

  def up do
    execute("ALTER TABLE analytics_dimensions DROP CONSTRAINT analytics_dimensions_shape_check")

    execute("""
    ALTER TABLE analytics_dimensions ADD CONSTRAINT analytics_dimensions_shape_check CHECK (
      dimension IN ('path', 'hostname', 'event', 'referrer', 'country', 'browser') AND
      octet_length(value) BETWEEN 1 AND 512 AND visitors >= 0 AND pageviews >= 0
    )
    """)
  end

  def down do
    execute("ALTER TABLE analytics_dimensions DROP CONSTRAINT analytics_dimensions_shape_check")

    execute("""
    ALTER TABLE analytics_dimensions ADD CONSTRAINT analytics_dimensions_shape_check CHECK (
      dimension IN ('path', 'hostname', 'event') AND
      octet_length(value) BETWEEN 1 AND 512 AND visitors >= 0 AND pageviews >= 0
    )
    """)
  end
end
