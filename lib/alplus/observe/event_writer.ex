defmodule Alplus.Observe.EventWriter do
  @moduledoc """
  The optimized Observe ingest writer.

  Error events are partitioned raw data, so this module deliberately bypasses
  Ash for the hot transaction. Issues remain Ash resources for lifecycle UI.
  """

  alias Alplus.Billing.EventMeter
  alias Alplus.Observe.{AlertWorker, Fingerprint, PayloadStorageWorker}
  alias Alplus.Repo

  # Sentry's default stacktrace frame limit. The full, untrimmed set is never
  # lost — it overflows to S3 behind `payload_s3_key` (see `PayloadStore`)
  # and is fetchable on demand; this only bounds the inline `error_events` row.
  @max_stored_frames 50

  @type event :: %{
          required(:event_id) => String.t(),
          required(:org_id) => String.t(),
          required(:project_id) => String.t(),
          required(:source_id) => String.t(),
          required(:environment) => String.t(),
          required(:occurred_at) => DateTime.t(),
          required(:received_at) => DateTime.t(),
          required(:level) => String.t(),
          required(:sdk_name) => String.t(),
          required(:sdk_version) => String.t(),
          optional(:message) => String.t() | nil,
          optional(:exception_type) => String.t() | nil,
          optional(:exception_value) => String.t() | nil,
          optional(:frames) => [map()] | nil,
          optional(:causes) => [map()] | nil,
          optional(:user_id) => String.t() | nil,
          optional(:user_email) => String.t() | nil,
          optional(:mechanism) => String.t() | nil,
          optional(:custom_fingerprint) => [String.t()] | nil,
          optional(:release) => String.t() | nil,
          optional(:context) => map() | nil,
          optional(:tags) => map() | nil,
          optional(:breadcrumbs) => list() | nil,
          optional(:payload_s3_key) => String.t() | nil,
          optional(:payload_s3_payload) => binary() | nil
        }

  @spec record(event()) ::
          {:ok,
           %{
             issue_id: String.t(),
             event_id: String.t(),
             new_issue?: boolean,
             regression?: boolean
           }}
          | {:ok, :duplicate}
          | {:ok, :quota_dropped}
          | {:error, term()}
  def record(event) do
    case EventMeter.consume(event.org_id, :error_events, event.received_at) do
      %{accepted?: false} ->
        {:ok, :quota_dropped}

      %{accepted?: true} ->
        Repo.transaction(fn ->
          case claim_event_id(event) do
            :claimed ->
              issue = upsert_issue(event)
              insert_event(event, issue.id)
              enqueue_payload_job(event)
              enqueue_alert_job(event, issue)

              %{
                issue_id: issue.id,
                event_id: event.event_id,
                new_issue?: issue.new_issue?,
                regression?: issue.regression?
              }

            :duplicate ->
              Repo.rollback(:duplicate)
          end
        end)
        |> case do
          {:ok, result} ->
            {:ok, result}

          {:error, :duplicate} ->
            {:ok, :duplicate}

          {:error, reason} ->
            {:error, reason}
        end
    end
  end

  # Fully parameterized ($1, $2, ...); the SQL string itself is a fixed
  # compile-time literal with no interpolation.
  #
  # The arbiter is (org_id, project_id, source_id, event_id).
  # `error_event_deduplications` used to carry a PRIMARY KEY on `event_id`
  # alone, which deduplicated globally across every org/project (a second
  # org posting an `event_id` a first org already used was silently dropped
  # as `duplicate` -- a cross-tenant suppression bug) AND across every
  # Source within one project (a staging Source's event was dropped as a
  # duplicate of a production Source's event that reused the same
  # `event_id`, confirmed against dev). Both are fixed by this single
  # arbiter switch: same Source + same `event_id` still dedups (retry
  # protection); different org, project, or Source + same `event_id` are
  # all accepted independently. See
  # `20260816202000_add_error_event_dedup_source_id.exs`,
  # `20260816202100_add_error_event_dedup_source_index.exs`,
  # `20260816201300_drop_error_event_dedup_event_id_pkey.exs`, and
  # `docs/observe-source-id-phase-b.md`.
  #
  # The old `event_id`-only PRIMARY KEY is dropped in THIS release, in the
  # same migration set as this arbiter switch, not deferred: it is an
  # unconditional unique constraint, so leaving it in place would keep
  # blocking the exact bug this switch fixes (two different Sources reusing
  # an `event_id` would still hit an unhandled `unique_violation` on it).
  # Accepted single-release cost: during this release's Kamal cutover, any
  # ingest request still landing on the OLD container (still running
  # `ON CONFLICT (event_id)`) during the health-check drain window finds no
  # matching arbiter for that clause and 500s -- every request hitting the
  # old container in that window, not just colliding ones, until the load
  # balancer finishes draining it. Bounded by the health-check window; not
  # an ongoing risk past this one deploy.
  # sobelow_skip ["SQL.Query"]
  defp claim_event_id(event) do
    sql = """
    INSERT INTO error_event_deduplications (event_id, org_id, project_id, source_id, received_at)
    VALUES ($1, $2, $3, $4, $5)
    ON CONFLICT (org_id, project_id, source_id, event_id) DO NOTHING
    RETURNING event_id
    """

    case Repo.query!(sql, [
           event.event_id,
           event.org_id,
           event.project_id,
           event.source_id,
           event.received_at
         ]).rows do
      [[_event_id]] -> :claimed
      [] -> :duplicate
    end
  end

  defp enqueue_payload_job(%{
         event_id: event_id,
         received_at: received_at,
         project_id: project_id,
         payload_s3_key: key,
         payload_s3_payload: payload
       })
       when is_binary(key) and is_binary(payload) do
    outbox_id = Alplus.Id.generate("eout")

    Repo.query!(
      """
      INSERT INTO observe_error_payload_outboxes
        (id, event_received_at, event_id, project_id, payload_s3_key, payload)
      VALUES ($1, $2, $3, $4, $5, $6)
      """,
      [outbox_id, received_at, event_id, project_id, key, payload]
    )

    Oban.insert!(PayloadStorageWorker.new(%{"outbox_id" => outbox_id}))
    :ok
  end

  defp enqueue_payload_job(_event), do: :ok

  defp enqueue_alert_job(event, issue) do
    Oban.insert!(
      AlertWorker.new(%{
        "event_id" => event.event_id,
        "received_at" => DateTime.to_iso8601(event.received_at),
        "new_issue" => issue.new_issue?,
        "regression" => issue.regression?
      })
    )

    :ok
  end

  # Fully parameterized ($1, $2, ...); the SQL string itself is a fixed
  # compile-time literal with no interpolation.
  # sobelow_skip ["SQL.Query"]
  defp upsert_issue(event) do
    subject = %{
      project_id: event.project_id,
      environment: event.environment,
      level: event.level,
      custom_fingerprint: Map.get(event, :custom_fingerprint),
      exception_type: Map.get(event, :exception_type),
      exception_value: Map.get(event, :exception_value),
      message: Map.get(event, :message),
      frames: Map.get(event, :frames)
    }

    %{fingerprint: fingerprint} = Fingerprint.compute(subject)
    previous_status = previous_issue_status(event, fingerprint)
    now = event.received_at

    # Phase A (issue #46 follow-up, docs/observe-source-id-phase-b.md): the
    # conflict target stays (org_id, project_id, environment, fingerprint),
    # matching the still-live `issues_fingerprint_per_environment_index`.
    # `source_id` is written as a data column and refreshed on every
    # conflict (EXCLUDED.source_id) so a row always reflects the most
    # recent Source that wrote to it. Phase B moves the conflict target to
    # `source_id` in a later, separate deploy.
    sql = """
    INSERT INTO issues (
      id, org_id, project_id, source_id, environment, fingerprint, status, level, title, culprit,
      first_seen_at, last_seen_at, event_count, release_first_seen, release_last_seen,
      context_summary, retention_policy_version, inserted_at, updated_at
    ) VALUES ($1, $2, $3, $4, $5, $6, 'open', $7, $8, $9, $10, $10, 1, $11, $11, $12, 1, $10, $10)
    ON CONFLICT (org_id, project_id, environment, fingerprint) DO UPDATE
    SET source_id = EXCLUDED.source_id,
        last_seen_at = GREATEST(issues.last_seen_at, EXCLUDED.last_seen_at),
        event_count = issues.event_count + 1,
        level = EXCLUDED.level,
        release_last_seen = COALESCE(EXCLUDED.release_last_seen, issues.release_last_seen),
        status = CASE WHEN issues.status IN ('resolved', 'ignored') THEN 'open' ELSE issues.status END,
        resolved_at = NULL,
        resolved_in_release_id = NULL,
        ignored_until = NULL,
        updated_at = EXCLUDED.updated_at
    RETURNING id, (xmax = 0) AS new_issue
    """

    title = Fingerprint.title(subject) |> cap(1_024)
    culprit = Fingerprint.culprit(Map.get(event, :frames)) |> cap(1_024)
    release = Map.get(event, :release) |> cap(200)
    context_summary = Map.get(event, :context)

    %{rows: [[id, new_issue?]]} =
      Repo.query!(sql, [
        Alplus.Id.generate(:issue),
        event.org_id,
        event.project_id,
        event.source_id,
        event.environment,
        fingerprint,
        event.level,
        title,
        culprit,
        now,
        release,
        context_summary
      ])

    %{
      id: id,
      new_issue?: new_issue?,
      regression?: not new_issue? and previous_status in ["resolved", "ignored"]
    }
  end

  # This lock gives classification the same transaction boundary as the
  # upsert, so it targets the exact environment-keyed row that query updates.
  defp previous_issue_status(event, fingerprint) do
    %{rows: rows} =
      Repo.query!(
        """
        SELECT status FROM issues
        WHERE org_id = $1 AND project_id = $2 AND environment = $3 AND fingerprint = $4
        FOR UPDATE
        """,
        [event.org_id, event.project_id, event.environment, fingerprint]
      )

    case rows do
      [[status]] -> status
      [] -> nil
    end
  end

  # Fully parameterized ($1, $2, ...); the SQL string itself is a fixed
  # compile-time literal with no interpolation.
  # sobelow_skip ["SQL.Query"]
  defp insert_event(event, issue_id) do
    sql = """
    INSERT INTO error_events (
      received_at, event_id, issue_id, org_id, project_id, source_id, environment, occurred_at,
      level, message, exception_type, exception_value, frames, context, tags, breadcrumbs,
      release, sdk_name, sdk_version, payload_s3_key, user_id, user_email, mechanism, causes
    ) VALUES (
      $1, $2, $3, $4, $5, $6, $7, $8, $9, $10, $11, $12, $13, $14, $15, $16, $17, $18, $19, $20,
      $21, $22, $23, $24
    )
    """

    Repo.query!(sql, [
      event.received_at,
      event.event_id,
      issue_id,
      event.org_id,
      event.project_id,
      event.source_id,
      event.environment,
      event.occurred_at,
      event.level,
      Map.get(event, :message),
      Map.get(event, :exception_type),
      Map.get(event, :exception_value),
      event |> Map.get(:frames) |> cap_frames(),
      Map.get(event, :context),
      Map.get(event, :tags),
      Map.get(event, :breadcrumbs),
      Map.get(event, :release),
      event.sdk_name,
      event.sdk_version,
      Map.get(event, :payload_s3_key),
      event |> Map.get(:user_id) |> cap(512),
      event |> Map.get(:user_email) |> cap(512),
      event |> Map.get(:mechanism) |> cap(64),
      event |> Map.get(:causes) |> cap_causes()
    ])
  end

  defp cap(nil, _limit), do: nil
  defp cap(value, limit), do: String.slice(value, 0, limit)

  # Each cause's frames get the same inline bound as the top-level frames.
  # The chain depth itself is already bounded by the envelope parser.
  defp cap_causes(nil), do: nil

  defp cap_causes(causes) when is_list(causes) do
    Enum.map(causes, fn cause ->
      case Map.get(cause, :frames) do
        nil -> cause
        frames -> Map.put(cause, :frames, cap_frames(frames))
      end
    end)
  end

  # Bounds the frames stored inline on the `error_events` row. Below the cap,
  # nothing changes. Above it, every in-app frame is kept (that's what a
  # developer triages), and the remaining budget is split between the top and
  # bottom of the surrounding library frames, Sentry-style middle
  # truncation, rather than a naive first-N cut that could drop the actual
  # crash site. Never touches fingerprinting: `upsert_issue/1` computes the
  # fingerprint from the event's original, uncapped frames.
  defp cap_frames(nil), do: nil
  defp cap_frames(frames) when length(frames) <= @max_stored_frames, do: frames

  defp cap_frames(frames) do
    indexed = Enum.with_index(frames)

    {in_app, library} =
      Enum.split_with(indexed, fn {frame, _index} -> Fingerprint.in_app_frame?(frame) end)

    kept =
      if length(in_app) >= @max_stored_frames do
        Enum.take(in_app, @max_stored_frames)
      else
        budget = @max_stored_frames - length(in_app)
        top_budget = ceil(budget / 2)
        bottom_budget = budget - top_budget

        in_app ++ Enum.take(library, top_budget) ++ Enum.take(library, -bottom_budget)
      end

    kept
    |> Enum.uniq_by(fn {_frame, index} -> index end)
    |> Enum.sort_by(fn {_frame, index} -> index end)
    |> Enum.map(fn {frame, _index} -> frame end)
  end
end
