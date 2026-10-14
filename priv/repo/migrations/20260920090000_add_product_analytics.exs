defmodule Alplus.Repo.Migrations.AddProductAnalytics do
  @moduledoc """
  Product analytics (ADR 0007): the raw event table, the property-key
  registry, and the usage columns that meter ingest. Ash owns the
  configuration resources (saved funnels, per-project settings) and generates
  their migration separately.

  `product_events` is deliberately not partitioned. Every V1 question is
  answered from raw rows inside one bounded window
  (`Package.limit(:product_event_retention_days)`), and the retention job
  deletes by that window. Past roughly 500,000 rows in one project the funnel
  read stops being fast enough for a dashboard; ADR 0007 records the measured
  numbers and the migration path.
  """

  use Ecto.Migration

  def up do
    execute("SET lock_timeout = '3s'")

    alter table(:usage_periods) do
      add :product_events, :bigint, null: false, default: 0
      add :dropped_product_events, :bigint, null: false, default: 0
    end

    execute("""
    ALTER TABLE usage_periods ADD CONSTRAINT usage_periods_product_counts_check
    CHECK (product_events >= 0 AND dropped_product_events >= 0) NOT VALID
    """)

    execute("ALTER TABLE usage_periods VALIDATE CONSTRAINT usage_periods_product_counts_check")

    execute("""
    CREATE TABLE product_events (
      id text PRIMARY KEY,
      org_id text NOT NULL REFERENCES organizations(id) ON DELETE CASCADE,
      project_id text NOT NULL REFERENCES projects(id) ON DELETE CASCADE,
      source_id text NOT NULL REFERENCES sources(id) ON DELETE CASCADE,
      environment text NOT NULL,
      event_name text NOT NULL,
      distinct_id text NOT NULL,
      occurred_at timestamptz NOT NULL,
      received_at timestamptz NOT NULL DEFAULT now(),
      properties jsonb NOT NULL DEFAULT '{}'::jsonb,
      client_event_id text,
      CONSTRAINT product_events_environment_check CHECK (octet_length(environment) BETWEEN 1 AND 64),
      CONSTRAINT product_events_event_name_check CHECK (octet_length(event_name) BETWEEN 1 AND 120),
      CONSTRAINT product_events_distinct_id_check CHECK (octet_length(distinct_id) BETWEEN 1 AND 200),
      CONSTRAINT product_events_client_event_id_check CHECK (client_event_id IS NULL OR octet_length(client_event_id) BETWEEN 4 AND 64),
      CONSTRAINT product_events_properties_size_check CHECK (octet_length(properties::text) <= 8192),
      CONSTRAINT product_events_properties_object_check CHECK (jsonb_typeof(properties) = 'object')
    )
    """)

    # The four reads this table serves, in order of how often they run: the
    # live feed and the overall trend; the event explorer and event detail;
    # funnels and retention, which walk one person's events in time order.
    execute(
      "CREATE INDEX product_events_project_occurred_at_index ON product_events (project_id, occurred_at DESC)"
    )

    execute(
      "CREATE INDEX product_events_project_event_occurred_at_index ON product_events (project_id, event_name, occurred_at DESC)"
    )

    execute(
      "CREATE INDEX product_events_project_distinct_occurred_at_index ON product_events (project_id, distinct_id, occurred_at)"
    )

    # At-least-once ingest plus deduplication (spec §6): a retry that carries
    # the same client id writes nothing the second time.
    execute("""
    CREATE UNIQUE INDEX product_events_project_client_id_index
    ON product_events (project_id, client_event_id)
    WHERE client_event_id IS NOT NULL
    """)

    # No index on `properties`. A property filter compares
    # `properties ->> 'key'` to text, which a `jsonb_path_ops` GIN index
    # cannot serve: that operator class answers containment (`@>`), not
    # key extraction. `scripts/benchmark-analytics-queries.exs` confirmed the
    # planner ignored the index at one million rows and that dropping it left
    # the filtered query unchanged, so it was pure write and storage cost.
    #
    # Using `@>` instead would make the index usable but would compare JSON
    # types rather than text, so a filter would stop agreeing with the
    # breakdown that produced its value. The filter therefore rides the
    # project and range btree above.

    # The breakdown and filter pickers read this registry instead of scanning
    # events for distinct property names. Ingest caps the row count per event
    # name, so a client that invents a property name per request cannot grow
    # it without bound.
    execute("""
    CREATE TABLE product_event_property_keys (
      org_id text NOT NULL REFERENCES organizations(id) ON DELETE CASCADE,
      project_id text NOT NULL REFERENCES projects(id) ON DELETE CASCADE,
      event_name text NOT NULL,
      property_key text NOT NULL,
      last_seen_at timestamptz NOT NULL DEFAULT now(),
      PRIMARY KEY (project_id, event_name, property_key),
      CONSTRAINT product_event_property_keys_event_name_check CHECK (octet_length(event_name) BETWEEN 1 AND 120),
      CONSTRAINT product_event_property_keys_property_key_check CHECK (octet_length(property_key) BETWEEN 1 AND 64)
    )
    """)
  end

  def down do
    execute("DROP TABLE product_event_property_keys")
    execute("DROP TABLE product_events")

    execute("ALTER TABLE usage_periods DROP CONSTRAINT usage_periods_product_counts_check")

    alter table(:usage_periods) do
      remove :dropped_product_events
      remove :product_events
    end
  end
end
