defmodule Alplus.Analytics.PropertyRegistryTest do
  @moduledoc """
  The property-name registry is what the breakdown and filter pickers read.
  A project whose pickers empty out, or whose registry grows without bound,
  both break the same screen.
  """

  use Alplus.DataCase, async: false

  import Alplus.OrgsFixtures

  alias Alplus.Analytics.{Ingest, Limits, Queries}
  alias Alplus.Repo

  setup do
    scope = scope_fixture()
    {org, owner_scope} = org_fixture(scope)
    subscribed_fixture(org)
    project = project_fixture(owner_scope, org)
    {source, _secret} = source_fixture(owner_scope, org, project, %{type: :analytics})

    %{
      org: org,
      project: project,
      source: source,
      scope: Alplus.Scope.put_project(owner_scope, project.id)
    }
  end

  defp send_event(source, properties) do
    {:ok, [event]} =
      Ingest.normalize(
        [%{"event" => "paywall_viewed", "properties" => properties}],
        DateTime.utc_now()
      )

    {:ok, _result} = Ingest.write(source, [event])
  end

  defp last_seen(project, key) do
    %{rows: [[at]]} =
      Repo.query!(
        "SELECT last_seen_at FROM product_event_property_keys WHERE project_id = $1 AND property_key = $2",
        [project.id, key]
      )

    at
  end

  test "registers each property name once, for the picker to read", context do
    send_event(context.source, %{"source" => "onboarding", "variant" => "a"})
    send_event(context.source, %{"source" => "settings"})

    assert Queries.property_keys(context.scope, "paywall_viewed") == ["source", "variant"]
  end

  test "keeps refreshing a known name after the per-event cap is reached", context do
    cap = Limits.property_keys_per_event()

    rows = for index <- 1..cap, do: "filler_#{index}"

    Repo.query!(
      """
      INSERT INTO product_event_property_keys (org_id, project_id, event_name, property_key, last_seen_at)
      SELECT $1, $2, 'paywall_viewed', key, now() - interval '100 days'
      FROM unnest($3::text[]) AS key
      """,
      [context.org.id, context.project.id, rows]
    )

    send_event(context.source, %{"filler_1" => "still in use"})

    refreshed = last_seen(context.project, "filler_1")
    assert NaiveDateTime.diff(refreshed, NaiveDateTime.utc_now(), :second) > -60
  end

  test "stops registering new names once the per-event cap is reached", context do
    cap = Limits.property_keys_per_event()
    rows = for index <- 1..cap, do: "filler_#{index}"

    Repo.query!(
      """
      INSERT INTO product_event_property_keys (org_id, project_id, event_name, property_key)
      SELECT $1, $2, 'paywall_viewed', key FROM unnest($3::text[]) AS key
      """,
      [context.org.id, context.project.id, rows]
    )

    send_event(context.source, %{"one_name_too_many" => "x"})

    refute "one_name_too_many" in Queries.property_keys(context.scope, "paywall_viewed")
  end
end
