# frozen_string_literal: true

module PostDeploy
  # Records application log lines as breadcrumbs (issue #47): every
  # `Logger#add` on an attached logger becomes a `log`-category breadcrumb
  # on the current thread's `Scope` ring (before-error context) and is
  # offered to any pending exception item inside its post-error log window
  # (after-error context). Attached to `Rails.logger` by the Railtie;
  # usable on any stdlib-compatible logger via `attach`.
  #
  # Excluded on purpose: the SDK's own `[postdeploy]` diagnostics (the timeline
  # must hold the application's output, not the SDK talking to itself), and
  # non-String messages (the block form is not evaluated here — evaluating
  # it early would change the host's lazy-logging semantics).
  module LoggerBreadcrumbs
    SEVERITY_LEVEL = {
      0 => "debug", 1 => "info", 2 => "warning", 3 => "error", 4 => "fatal"
    }.freeze
    SDK_INTERNAL_PREFIX = "[postdeploy]"

    # Prepended onto the logger's singleton class so both a plain
    # `::Logger` and Rails' `ActiveSupport::BroadcastLogger` (whose `add`
    # fans out to its broadcasts) are covered by one seam.
    module Recorder
      def add(severity, message = nil, progname = nil, &block)
        PostDeploy::LoggerBreadcrumbs.record(severity, message, progname)
        super
      end
    end

    module_function

    def attach(logger)
      return if logger.nil? || logger.singleton_class.ancestors.include?(Recorder)

      logger.singleton_class.prepend(Recorder)
    end

    # Never raises, and never re-enters (a breadcrumb path that itself logs
    # would otherwise recurse through the patched `add`).
    def record(severity, message, progname)
      config = PostDeploy.configuration
      return unless config&.logger_breadcrumbs_enabled
      return if Thread.current[:postdeploy_recording_log_breadcrumb]

      text = message.is_a?(String) ? message : (progname if progname.is_a?(String) && message.nil?)
      return if text.nil? || text.empty? || text.start_with?(SDK_INTERNAL_PREFIX)

      Thread.current[:postdeploy_recording_log_breadcrumb] = true
      level = SEVERITY_LEVEL.fetch(severity, "info")
      Scope.current.add_breadcrumb(category: "log", message: text, level: level)
      PostDeploy.initialized_client&.notify_log_breadcrumb(
        category: "log",
        message: Envelope.cap_text(text, Envelope::MAX_BREADCRUMB_MESSAGE_CHARS),
        level: level,
        ts: Time.now.utc.iso8601(3)
      )
    rescue StandardError
      nil
    ensure
      Thread.current[:postdeploy_recording_log_breadcrumb] = nil
    end
  end
end
