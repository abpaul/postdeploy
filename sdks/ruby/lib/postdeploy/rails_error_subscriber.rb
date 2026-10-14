# frozen_string_literal: true

module PostDeploy
  # Rails 7+ error reporter subscriber (`Rails.error.subscribe`). Forwards
  # only HANDLED reports (`Rails.error.handle`/`Rails.error.record`, or any
  # library that reports through `Rails.error`) — an UNHANDLED exception
  # already reaches `PostDeploy::RackMiddleware` (installed directly around the
  # app, inside `ActionDispatch::ShowExceptions`) as it propagates up the
  # middleware stack. Subscribing to `handled: false` here too would
  # double-report the same exception on Rails versions that also route
  # unhandled request exceptions through the error reporter.
  class RailsErrorSubscriber
    def report(error, handled:, severity:, context:, source: nil)
      return unless handled

      PostDeploy.capture_exception(error, level: severity_to_level(severity), context: context, mechanism: "rails.error_reporter")
    end

    private

    def severity_to_level(severity)
      { error: "error", warning: "warning", info: "info" }.fetch(severity, "error").to_s
    end
  end
end
