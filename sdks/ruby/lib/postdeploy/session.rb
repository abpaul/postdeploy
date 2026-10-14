# frozen_string_literal: true

module PostDeploy
  # Request-scoped session-health tracker for PostDeploy Observe's crash-free
  # sessions metric (issue #12). One request = one session, Sentry
  # "request-mode" style: `PostDeploy::RackMiddleware` opens it, this class
  # accumulates its outcome as the request runs, and the middleware closes
  # it once `@app.call` returns (or raises).
  #
  # State lives on `Thread.current`, exactly like `Scope` and for the same
  # reason: a thread-pool server (Puma, Passenger) reuses OS threads across
  # requests, so this must be reset per request rather than shared.
  #
  # Three outcomes, in ascending severity, matching
  # ARCHITECTURE.md's decision #2 (Sentry-aligned):
  #
  #   * `:healthy` -- the request completed with no captured error.
  #   * `:errored` -- the request captured a handled error (any
  #     `PostDeploy.capture_exception`/`capture_message` at level
  #     `"error"`/`"fatal"`).
  #   * `:crashed` -- the request raised an exception that propagated,
  #     unhandled, up through `RackMiddleware`. Only this state counts
  #     against crash-free sessions.
  #
  # Severity only ever increases within one request: `mark_errored` is a
  # no-op once `mark_crashed` has run (`RackMiddleware`'s rescue calls
  # `PostDeploy.capture_exception` for the crash itself, which would otherwise
  # downgrade the outcome back to `:errored`).
  class Session
    THREAD_KEY = :postdeploy_session
    private_constant :THREAD_KEY

    SEVERITY = { healthy: 0, errored: 1, crashed: 2 }.freeze
    private_constant :SEVERITY

    class << self
      # The current thread/fiber's session, or `nil` if none was started
      # (e.g. outside `RackMiddleware`, such as a background job).
      def current
        Thread.current[THREAD_KEY]
      end

      # Replaces the current thread's session with a fresh one and yields;
      # restores whatever session (if any) was active before, even if the
      # block raises. `RackMiddleware` wraps each request in this so a
      # session from request A never leaks into request B on a reused
      # thread-pool thread.
      def with_clean_session
        previous = Thread.current[THREAD_KEY]
        Thread.current[THREAD_KEY] = new
        yield
      ensure
        Thread.current[THREAD_KEY] = previous
      end
    end

    attr_reader :id, :status

    def initialize
      @id = Id.generate_session_id
      @status = :healthy
    end

    # Marks the session `:errored`, unless it is already `:crashed`.
    def mark_errored
      bump(:errored)
    end

    # Marks the session `:crashed`. Terminal: never downgraded within one request.
    def mark_crashed
      bump(:crashed)
    end

    private

    def bump(new_status)
      @status = new_status if SEVERITY.fetch(new_status) > SEVERITY.fetch(@status)
    end
  end
end
