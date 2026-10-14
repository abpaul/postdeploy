# frozen_string_literal: true

module PostDeploy
  # Auto-breadcrumbs from `ActiveSupport::Notifications` (Rails only):
  # pushes a small, bounded set of framework events into the current
  # request's `Scope` as breadcrumbs, so a captured exception's timeline
  # shows "what happened just before this" without the host app calling
  # `PostDeploy.add_breadcrumb` by hand (mirrors Sentry's/AppSignal's
  # instrumentation breadcrumbs).
  #
  # Wired from `Railtie#install!` (guarded there too) -- a total no-op
  # outside Rails/`ActiveSupport`, and never subscribed twice even if a
  # host process boots more than one `Rails::Application` (test suites do
  # this routinely).
  #
  # Deliberately a SMALL, fixed event list: more events means more noise
  # per request and a bigger cut of the `Scope`'s bounded breadcrumb ring
  # buffer (`Scope::MAX_BREADCRUMBS`) spent on framework chatter instead of
  # the host app's own `add_breadcrumb` calls.
  module NotificationsSubscriber
    EVENTS = %w[sql.active_record process_action.action_controller start_processing.action_controller].freeze

    class << self
      # Idempotent: a second call (e.g. a second `Rails::Application` boot
      # in the same process, common in test suites) is a no-op.
      def install!
        return if @installed
        return unless defined?(::ActiveSupport::Notifications)

        EVENTS.each do |event_name|
          ::ActiveSupport::Notifications.subscribe(event_name) do |*args|
            handle(event_name, ::ActiveSupport::Notifications::Event.new(*args))
          end
        end
        @installed = true
      end

      # Test-only: lets a spec re-install (e.g. against a stubbed
      # `Scope`/`Configuration`) without carrying state from a previous
      # example. Not called by production code.
      def reset!
        @installed = false
      end

      # Fail-safe: instrumentation must never break the request it is
      # observing. Any error here (a payload shape this Rails version
      # doesn't produce, a `Scope` write racing shutdown, etc.) is
      # swallowed.
      def handle(event_name, notification)
        return unless breadcrumbs_enabled?

        breadcrumb = build_breadcrumb(event_name, notification)
        return unless breadcrumb

        Scope.current.add_breadcrumb(**breadcrumb)
      rescue StandardError
        nil
      end

      private

      def breadcrumbs_enabled?
        PostDeploy.configuration.breadcrumbs_enabled
      rescue StandardError
        false
      end

      def build_breadcrumb(event_name, notification)
        case event_name
        when "sql.active_record"
          sql_breadcrumb(notification)
        when "process_action.action_controller"
          process_action_breadcrumb(notification)
        when "start_processing.action_controller"
          start_processing_breadcrumb(notification)
        end
      end

      # `payload[:binds]` (the actual bound parameter VALUES -- e.g. a
      # looked-up email or password hash) is deliberately never read here.
      # Only the query name and the (already-parameterized, `?`-holed)
      # `payload[:sql]` text are kept.
      def sql_breadcrumb(notification)
        payload = notification.payload
        return nil if payload[:name] == "SCHEMA"

        { message: payload[:sql].to_s, category: "query", level: "info",
          data: { name: payload[:name], duration_ms: notification.duration.round(1) }.compact }
      end

      def process_action_breadcrumb(notification)
        payload = notification.payload
        { message: "#{payload[:controller]}##{payload[:action]}", category: "http", level: "info",
          data: { status: payload[:status], method: payload[:method] }.compact }
      end

      # No request params in the breadcrumb data: params routinely carry
      # user-entered PII, and this event fires before the built-in
      # scrubber (`Scrubber`, which only walks `context`/`contexts`/
      # `tags`/`user` at capture time) ever sees it.
      def start_processing_breadcrumb(notification)
        payload = notification.payload
        { message: "#{payload[:method]} #{payload[:path]}", category: "http", level: "info" }
      end
    end
  end
end
