# frozen_string_literal: true

require_relative "postdeploy/version"
require_relative "postdeploy/id"
require_relative "postdeploy/scrubber"
require_relative "postdeploy/configuration"
require_relative "postdeploy/stack"
require_relative "postdeploy/envelope"
require_relative "postdeploy/retry"
require_relative "postdeploy/transport"
require_relative "postdeploy/worker"
require_relative "postdeploy/dedup"
require_relative "postdeploy/scope"
require_relative "postdeploy/session"
require_relative "postdeploy/pending_window"
require_relative "postdeploy/client"
require_relative "postdeploy/logger_breadcrumbs"
require_relative "postdeploy/rack_middleware"
require_relative "postdeploy/heartbeat"

# Error reporting for `POST /e/errors` on PostDeploy Observe. Mirrors the wire
# contract of `@postdeploy/sdk` (TypeScript) and the Elixir SDK (see
# docs/ARCHITECTURE.md §8, docs/BUILD.md §5).
#
#   PostDeploy.configure do |config|
#     config.key = ENV["POSTDEPLOY_API_KEY"]      # alp_... ingest key, `ingest` scope
#     config.environment = "production"
#     config.release = "v1.2.3"
#   end
#
#   PostDeploy.capture_exception(exception)
#   PostDeploy.capture_message("something happened", level: "warning")
#
# Never raises into the host app: every public method here swallows its own
# internal errors and always returns the generated `err_` event id.
module PostDeploy
  # Guards the `@client`/`@configuration` singleton memoization below.
  # Module-level (not lazily built) so there is no first-access race on the
  # mutex itself.
  CLIENT_MUTEX = Mutex.new
  private_constant :CLIENT_MUTEX

  class << self
    def configuration
      @configuration ||= Configuration.new
    end

    def configure
      yield(configuration) if block_given?
      CLIENT_MUTEX.synchronize { @client = nil }
      configuration
    end

    # Memoized under a mutex: two threads racing the very first capture
    # call must not each construct a `Client` (and, with it, a second
    # background `Worker` thread).
    def client
      return @client if @client

      CLIENT_MUTEX.synchronize { @client ||= Client.new(configuration) }
    end

    # The memoized client if one exists, without constructing it. The
    # log-breadcrumb hook (issue #47) uses this: a boot-time log line must
    # not force client construction before the host finishes configuring.
    def initialized_client
      @client
    end

    def capture_exception(exception, **options)
      client.capture_exception(exception, **options)
    rescue StandardError
      Id.generate_event_id
    end

    def capture_message(message, **options)
      client.capture_message(message, **options)
    rescue StandardError
      Id.generate_event_id
    end

    # Blocks up to `timeout` seconds for the background queue to drain.
    # Mainly useful in tests and at the end of a short-lived script.
    def flush(timeout: 2)
      client.flush(timeout: timeout)
    rescue StandardError
      false
    end

    # `ping_id` is optional for legacy callers. When present, the server
    # deduplicates it per monitor for 24 hours.
    def heartbeat(token, state: "finish", ping_id: nil)
      Heartbeat.ping(token, state: state, ping_id: ping_id, config: configuration)
      nil
    rescue StandardError
      nil
    end

    # Request-scoped scope ergonomics (issue #17): set once (typically at
    # the top of a request, e.g. in a `before_action`) and applied to every
    # `capture_exception`/`capture_message` call for the rest of the
    # current thread/request. See `Scope`. Every setter is fail-safe.
    def set_user(user)
      Scope.current.set_user(user)
      nil
    rescue StandardError
      nil
    end

    def set_tag(key, value)
      Scope.current.set_tag(key, value)
      nil
    rescue StandardError
      nil
    end

    def set_context(name, data)
      Scope.current.set_context(name, data)
      nil
    rescue StandardError
      nil
    end

    def add_breadcrumb(message: nil, category: nil, level: nil, data: nil, ts: nil)
      Scope.current.add_breadcrumb(message: message, category: category, level: level, data: data, ts: ts)
      nil
    rescue StandardError
      nil
    end

    # Closes the current thread's request-scoped `Session` (issue #12), if
    # one is active (see `RackMiddleware`): reports it to
    # `POST /e/sessions` via `Client#report_session`. A no-op if no session
    # is active. Fail-safe: never raises. Not typically called directly —
    # `RackMiddleware` calls this once `@app.call` returns or raises.
    def close_session
      session = Session.current
      return nil unless session

      client.report_session(session)
      nil
    rescue StandardError
      nil
    end

    # :nodoc: host tests use `PostDeploy::Testing`.
    def test_transport
      client.transport
    end

    # :nodoc: host tests use `PostDeploy::Testing.reset!`.
    def reset!
      CLIENT_MUTEX.synchronize { @client = nil }
      @configuration = nil
      Dedup.reset!
    end
  end
end

require_relative "postdeploy/testing"
require_relative "postdeploy/railtie" if defined?(::Rails::Railtie)

# Optional integrations (issue: SDK parity #4/#5): only loaded/activated
# when the host app already loaded the corresponding library. Neither gem
# is ever `require`d by this file, and this SDK never declares either as a
# runtime dependency -- see `lib/postdeploy/sidekiq.rb`/`lib/postdeploy/active_job.rb`.
#
# This top-level block is the NON-RAILS fallback (or the case where the
# host requires `sidekiq`/`active_job` before `postdeploy`). Under Rails,
# `ActiveJob::Base` autoloads only after boot, so these `defined?` checks
# are false when the gem loads; the Railtie re-runs the install after boot
# with correct timing (see `railtie.rb`). `install!` is idempotent, so the
# two paths never double-install.
if defined?(::Sidekiq)
  require_relative "postdeploy/sidekiq"
  PostDeploy::Sidekiq.install!
end

if defined?(::ActiveJob::Base)
  require_relative "postdeploy/active_job"
  PostDeploy::ActiveJob.install!
end
