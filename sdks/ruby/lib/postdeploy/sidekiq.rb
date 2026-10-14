# frozen_string_literal: true

module PostDeploy
  # Optional Sidekiq integration. Namespaced under `PostDeploy::Sidekiq` (not
  # top-level) so this file never collides with the real `::Sidekiq`
  # constant it wraps -- `ErrorHandler` below refers to it explicitly via
  # `::Sidekiq` wherever the ambiguity would otherwise resolve to
  # `PostDeploy::Sidekiq` instead.
  #
  # This whole file is safe to load unconditionally (it defines classes,
  # nothing more) -- `postdeploy.rb` only `require_relative`s it when
  # `defined?(::Sidekiq)` is already true, and `install!` itself re-checks
  # that guard, so a host app that never loads the `sidekiq` gem never
  # pays for or activates any of this. The gem's runtime dependency list
  # stays empty either way (`sidekiq` is never `require`d from here).
  module Sidekiq
    # Sidekiq server middleware: captures a job's raised exception with
    # job context (class, queue, scrubbed args), then RE-RAISES so
    # Sidekiq's own retry/dead-set handling still runs unchanged -- this
    # is an observer, not an error handler that swallows failures.
    class ErrorHandler
      def call(worker, job, queue)
        yield
      rescue Exception => e # rubocop:disable Lint/RescueException
        capture(worker, job, queue, e)
        raise
      end

      private

      def capture(worker, job, queue, exception)
        PostDeploy.capture_exception(
          exception,
          mechanism: "sidekiq",
          contexts: { job: job_context(worker, job, queue) }
        )
      rescue StandardError
        nil
      end

      def job_context(worker, job, queue)
        {
          class: job["class"] || job["wrapped"] || worker.class.name,
          queue: queue || job["queue"],
          jid: job["jid"],
          args: Scrubber.deep_scrub(job["args"], PostDeploy.configuration.scrub_fields.map { |f| f.to_s.downcase })
        }.compact
      end
    end

    class << self
      # Idempotent: installs `ErrorHandler` onto Sidekiq's server
      # middleware chain exactly once per process, even if called more
      # than once (e.g. re-evaluated in a reloading dev environment).
      def install!
        return if @installed
        return unless defined?(::Sidekiq) && ::Sidekiq.respond_to?(:configure_server)

        ::Sidekiq.configure_server do |config|
          next unless config.respond_to?(:server_middleware)

          config.server_middleware do |chain|
            chain.add PostDeploy::Sidekiq::ErrorHandler unless chain.exists?(PostDeploy::Sidekiq::ErrorHandler)
          end
        end
        @installed = true
      end

      # Test-only: lets a spec re-drive `install!`. Not called by
      # production code.
      def reset!
        @installed = false
      end
    end
  end
end
