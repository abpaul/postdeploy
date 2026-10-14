# frozen_string_literal: true

require "net/http"
require "uri"
require "securerandom"
require "timeout"

module PostDeploy
  # Cron/job liveness pings against Monitor's `GET|POST /h/:token`
  # (issue #16; docs/ARCHITECTURE.md §8): the token is the auth (recognized
  # → 202 even paused, unrecognized → 404); `?state=start|finish|fail`, an
  # unrecognized state falls back to `finish` (still records the run,
  # matching the Elixir SDK) rather than silently no-op-ing. Mirrors
  # `packages/sdk/src/core/heartbeat.ts`'s wire contract and reuses `Retry`
  # (issue #15) for backoff/`Retry-After` instead of duplicating it — see
  # `Retry`'s comment on why Ruby shares this where the JS SDK deliberately
  # doesn't.
  #
  # `PostDeploy.heartbeat` (the public entry point in `postdeploy.rb`) calls
  # `ping` synchronously on the caller's thread. A cron/job runner wants the
  # ping sent before the process exits, not left in a background thread that
  # may never run. Each call is bounded to two five-second attempts and a
  # two-second delta-seconds `Retry-After` cap, so a persistent failure blocks
  # for at most about 12 seconds.
  module Heartbeat
    VALID_STATES = %w[start finish fail].freeze
    HEARTBEAT_MAX_ATTEMPTS = 2
    HEARTBEAT_MAX_RETRY_AFTER_SECONDS = 2
    HEARTBEAT_ATTEMPT_TIMEOUT_SECONDS = 5
    HEARTBEAT_RETRYABLE_STATUSES = [408, 429].concat((500..599).to_a).freeze
    module_function

    # Never raises: an internal error, network failure, or retryable
    # non-ok response is retried (bounded, see module doc) and then
    # swallowed, logged via `config.logger` if the retry budget is
    # exhausted. Returns `nil` always.
    #
    # The SAME `ping_id` is reused on every retry attempt within one call
    # (issue #16 defect): ingest dedups a retried ping on `ping_id`, so
    # reusing it — instead of minting a fresh id per HTTP attempt — is what
    # keeps a retried fail/finish from being processed as two separate
    # events (a duplicate incident/notification).
    def ping(token, state: "finish", config: PostDeploy.configuration, sleeper: method(:sleep), ping_id: nil)
      resolved_state = VALID_STATES.include?(state.to_s) ? state.to_s : "finish"
      resolved_ping_id = ping_id || generate_ping_id
      uri = build_uri(token, resolved_state, resolved_ping_id, config)

      result = Retry.perform(
        sleeper: sleeper,
        max_attempts: HEARTBEAT_MAX_ATTEMPTS,
        max_retry_after_seconds: HEARTBEAT_MAX_RETRY_AFTER_SECONDS,
        retryable_statuses: HEARTBEAT_RETRYABLE_STATUSES
      ) { |_attempt| post(uri, config) }

      if result.outcome == :exhausted
        detail = result.error ? "#{result.error.class}: #{result.error.message}" : "status #{result.response&.code}"
        detail = detail.gsub(token.to_s, "[REDACTED]")
        config.logger&.warn("[postdeploy] heartbeat exhausted #{HEARTBEAT_MAX_ATTEMPTS} attempt(s) (token [REDACTED], state #{resolved_state.inspect}): #{detail}")
      end
      nil
    rescue StandardError => e
      detail = e.message.to_s.gsub(token.to_s, "[REDACTED]")
      config.logger&.warn("[postdeploy] heartbeat failed internally: #{e.class}: #{detail}")
      nil
    end

    def generate_ping_id
      SecureRandom.uuid
    end

    # Exposed for tests asserting the exact URL shape; not otherwise part
    # of the public surface.
    def build_uri(token, state, ping_id, config)
      base = config.endpoint.to_s.sub(%r{/+\z}, "")
      uri = URI.parse("#{base}/h/#{URI.encode_www_form_component(token)}")
      uri.query = URI.encode_www_form(state: state, ping_id: ping_id)
      uri
    end

    def post(uri, config)
      http = Net::HTTP.new(uri.host, uri.port)
      http.use_ssl = uri.scheme == "https"
      timeout = [config.open_timeout.to_f, HEARTBEAT_ATTEMPT_TIMEOUT_SECONDS].min
      read_timeout = [config.read_timeout.to_f, HEARTBEAT_ATTEMPT_TIMEOUT_SECONDS].min
      http.open_timeout = timeout
      http.read_timeout = read_timeout

      Timeout.timeout(HEARTBEAT_ATTEMPT_TIMEOUT_SECONDS) do
        http.request(Net::HTTP::Post.new(uri.request_uri))
      end
    end
  end
end
