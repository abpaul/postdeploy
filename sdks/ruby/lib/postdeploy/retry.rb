# frozen_string_literal: true

module PostDeploy
  # Shared retry/backoff loop for both `Transport` (`POST /e/errors`) and
  # `Heartbeat` (`POST /h/:token`) — issue #16 explicitly asks the two share
  # this, unlike the JS SDK's `transport.ts`/`heartbeat.ts`, which duplicate
  # it deliberately because heartbeat there already shipped and touching it
  # was the higher-risk move. Both Ruby callers land in this change
  # together, so that risk does not apply here.
  #
  # Constants (3 attempts, 500ms jittered exponential base, 30s Retry-After
  # cap) mirror `packages/sdk/src/core/observe/transport.ts` byte-for-byte
  # so all SDKs back off the same way against the same ingest endpoint.
  module Retry
    MAX_ATTEMPTS = 3
    BACKOFF_BASE_SECONDS = 0.5
    BACKOFF_JITTER = 0.5
    MAX_RETRY_AFTER_SECONDS = 30
    # 400 (malformed request) and 401/403 (bad/scopeless key) and 404
    # (unrecognized route/token) can't be fixed by retrying.
    PERMANENT_STATUSES = [400, 401, 403, 404].freeze

    Result = Struct.new(:outcome, :response, :error, keyword_init: true) do
      def sent?
        outcome == :sent
      end
    end

    module_function

    # Calls the block up to `max_attempts` times (default `MAX_ATTEMPTS`).
    # The block must return a `Net::HTTPResponse` or raise. Sleeps between
    # attempts via `sleeper` (injectable so specs never wait on real
    # wall-clock time). A 429's `Retry-After` is capped at
    # `max_retry_after_seconds` (default `MAX_RETRY_AFTER_SECONDS`) —
    # `Heartbeat` passes a much lower cap so a caller pinging synchronously
    # can never be made to block anywhere near the server's full 30s cap.
    # Never raises: a block error on the final attempt is captured on the
    # returned `Result`, not re-raised.
    def perform(
      sleeper: method(:sleep),
      max_attempts: MAX_ATTEMPTS,
      max_retry_after_seconds: MAX_RETRY_AFTER_SECONDS,
      retryable_statuses: nil
    )
      result = nil

      max_attempts.times do |i|
        attempt = i + 1
        begin
          response = yield(attempt)

          if response.is_a?(Net::HTTPSuccess)
            return Result.new(outcome: :sent, response: response)
          end

          code = response.code.to_i
          if PERMANENT_STATUSES.include?(code)
            return Result.new(outcome: :permanent, response: response)
          end

          unless retryable_statuses.nil? || retryable_statuses.include?(code)
            return Result.new(outcome: :permanent, response: response)
          end

          result = Result.new(outcome: :exhausted, response: response)
          unless attempt == max_attempts
            delay =
              if code == 429
                retry_after_seconds(response, max_retry_after_seconds) || backoff_seconds(attempt)
              else
                backoff_seconds(attempt)
              end
            sleeper.call(delay)
          end
        rescue StandardError => e
          result = Result.new(outcome: :exhausted, error: e)
          sleeper.call(backoff_seconds(attempt)) unless attempt == max_attempts
        end
      end

      result
    end

    def backoff_seconds(attempt)
      exponential = BACKOFF_BASE_SECONDS * (2**(attempt - 1))
      jitter_factor = (1 - BACKOFF_JITTER) + (rand * 2 * BACKOFF_JITTER)
      exponential * jitter_factor
    end

    def retry_after_seconds(response, max_seconds = MAX_RETRY_AFTER_SECONDS)
      value = response["Retry-After"]
      return nil unless value&.match?(/\A[0-9]+\z/)

      [value.to_i, max_seconds].min
    end
  end
end
