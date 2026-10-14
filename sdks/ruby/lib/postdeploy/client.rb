# frozen_string_literal: true

module PostDeploy
  # Orchestrates one configuration's capture pipeline: builds the wire item,
  # wraps it in an envelope, and hands it to the background worker (or, in
  # test mode, sends it synchronously through the in-memory transport).
  #
  # Every public method is fail-safe: a bug anywhere in envelope building or
  # dispatch is caught and logged, never raised into the host app (issue
  # #14 story 8). The event id is always generated and returned first, so a
  # caller can show "reference id err_..." even if the event was dropped.
  class Client
    # `sleeper:` is forwarded to the default `Transport` (never used when
    # `config.transport`/`config.test_mode` supply a different one) purely
    # as a test seam: with the real `Kernel#sleep`, a spec exercising a
    # retried send would otherwise wait on real backoff wall-clock time.
    # Defaults to `config.sleeper` so `PostDeploy.configure { |c| c.sleeper = ... }`
    # reaches the module-level singleton client too, not just a directly
    # constructed `Client.new`.
    def initialize(config, sleeper: config.sleeper)
      @config = config
      @transport = config.transport || (config.test_mode ? TestTransport.new : Transport.new(config, sleeper: sleeper))
      @worker = Worker.new(config, @transport, kind: :error)
      # A SEPARATE worker (own queue, own thread) from `@worker` (issue
      # #12 fix): see `Worker`'s class doc for why sharing one lane with
      # error delivery was a defect (head-of-line blocking + silent drops
      # under an error storm, exactly when crash-free data matters).
      @session_worker = Worker.new(config, @transport, kind: :session)

      @pending_window =
        PendingWindow.new(config.resolved_post_error_log_window_ms) { |item| deliver_item(item) }
    end

    attr_reader :transport

    # The enabled/sampled gate runs BEFORE dedup registration (issue #15
    # defect): a sampled-out or disabled capture must not occupy the
    # dedup slot, or it would suppress the NEXT (real) in-window capture
    # of the same error.
    #
    # Dedup (issue #15) then runs BEFORE the scope merge / envelope build:
    # the same exception object captured twice within the dedup window
    # (e.g. by `RackMiddleware` auto-capture and a manual rescue further up
    # the stack) returns the first call's id and is never re-queued — see
    # `Dedup`.
    #
    # `contexts:`/`fingerprint:` and the ambient `Scope` (`set_user`,
    # `set_tag`, `set_context`, `add_breadcrumb`) are issue #17: an explicit
    # per-call `user:`/`tags:`/`contexts:`/`breadcrumbs:` here wins over
    # whatever the ambient scope carries, field-by-field — see
    # `ScopeMerge.merge`. `user:` defaults to the `PostDeploy::UNSET` sentinel,
    # not `nil`, so a caller CAN pass `user: nil` to explicitly clear the
    # ambient user for one capture.
    def capture_exception(exception, level: "error", context: nil, contexts: nil, tags: nil, breadcrumbs: nil, user: PostDeploy::UNSET, mechanism: "generic", fingerprint: nil)
      mark_session_outcome(level)
      fresh_id = Id.generate_event_id
      return fresh_id unless enabled?
      return fresh_id if excluded?(exception)

      resolved = Dedup.resolve(exception, fresh_id)
      return resolved[:id] if resolved[:duplicate]

      id = resolved[:id]
      dispatch(id) { build_item(:exception_item, exception: exception, id: id, level: level, context: context, contexts: contexts, tags: tags, breadcrumbs: breadcrumbs, user: user, mechanism: mechanism, fingerprint: fingerprint) }
      id
    end

    def capture_message(message, level: "info", context: nil, contexts: nil, tags: nil, breadcrumbs: nil, user: PostDeploy::UNSET, mechanism: "generic", fingerprint: nil)
      mark_session_outcome(level)
      id = Id.generate_event_id
      return id unless enabled?

      dispatch(id) { build_item(:message_item, message: message, id: id, level: level, context: context, contexts: contexts, tags: tags, breadcrumbs: breadcrumbs, user: user, mechanism: mechanism, fingerprint: fingerprint) }
      id
    end

    # Flushes BOTH delivery lanes (issue #12: error and session are
    # independent workers). A slow/stuck error lane still bounds this call
    # by `timeout` for the session lane's own drain -- each `Worker#flush`
    # call gets the full `timeout` budget rather than splitting it, since a
    # caller flushing wants both drained, not a race between them.
    def flush(timeout: 2)
      # Seal the post-error log window first: flush means "send now with
      # whatever after-lines were collected so far", never "wait".
      @pending_window.seal_all!
      error_flushed = @worker.flush(timeout: timeout)
      session_flushed = @session_worker.flush(timeout: timeout)
      error_flushed && session_flushed
    rescue StandardError
      false
    end

    # Offers a log-line breadcrumb to every exception item currently inside
    # its post-error log window on this thread (issue #47). Never raises.
    def notify_log_breadcrumb(crumb)
      @pending_window.notify_log_breadcrumb(crumb)
    end

    # Reports a closed `Session` (issue #12) to `POST /e/sessions`, on its
    # OWN background `Worker` (own queue, own thread) so a slow/failing
    # `/e/errors` delivery can never delay or drop a queued session, or
    # vice versa -- see `Worker`'s class doc. Unlike `capture_exception`/
    # `capture_message`, never sampled or deduped — an accurate crash-free
    # percentage needs every session counted, not a sample of them. Only
    # gated on `config.valid?` (configured + enabled). Fail-safe: never
    # raises.
    def report_session(session)
      return false unless @config.valid?

      envelope = Envelope.wrap(config: @config, item: Envelope.session_item(session: session, config: @config))

      if @config.test_mode
        @transport.send_envelope(envelope, kind: :session)
      else
        @session_worker.enqueue(envelope)
      end
    rescue StandardError => e
      @config.logger&.warn("[postdeploy] session report failed internally; dropped: #{e.class}: #{e.message}")
      false
    end

    private

    # Any `"error"`/`"fatal"`-level capture during the current request
    # marks its `Session` (at least) `:errored` (issue #12) — a no-op if
    # the session is already `:crashed`, or if no session is active (e.g.
    # a background job, not a request under `RackMiddleware`). Runs
    # BEFORE the `enabled?`/sampling gate below: whether or not this
    # particular capture gets sent to `/e/errors`, the request genuinely
    # did produce a handled error.
    def mark_session_outcome(level)
      Session.current&.mark_errored if %w[error fatal].include?(level.to_s)
    end

    # Single evaluation point for "would this capture actually be sent":
    # `config.sampled?` draws a random number, so it must be called
    # exactly once per capture — calling it again later (e.g. inside
    # `dispatch`) could draw a different result than what already gated
    # dedup registration.
    def enabled?
      @config.valid? && @config.sampled?
    rescue StandardError
      false
    end

    # Merges the ambient `Scope` with this call's explicit overrides, then
    # delegates to `Envelope.exception_item`/`Envelope.message_item`.
    def build_item(builder, id:, level:, context:, contexts:, tags:, breadcrumbs:, user:, mechanism:, fingerprint:, **item_args)
      merged = ScopeMerge.merge(ambient: Scope.current.snapshot, user: user, tags: tags, contexts: contexts, breadcrumbs: breadcrumbs)
      Envelope.public_send(
        builder,
        id: id,
        config: @config,
        level: level,
        context: context,
        contexts: merged[:contexts].empty? ? nil : merged[:contexts],
        tags: merged[:tags].empty? ? nil : merged[:tags],
        breadcrumbs: merged[:breadcrumbs].empty? ? nil : merged[:breadcrumbs],
        user: merged[:user],
        mechanism: mechanism,
        fingerprint: fingerprint,
        **item_args
      )
    end

    # `id` is unused directly but kept as a named parameter for readability
    # at call sites and future correlation logging. The enabled/sampled
    # gate already ran in `capture_exception`/`capture_message` before
    # dedup registration, so it is not repeated here.
    def dispatch(_id)
      item = scrub_item(yield)
      item = apply_before_send(item)
      return unless item

      if item[:type] == "exception" && @pending_window.enabled?
        # Post-error log window (issue #47): the item lingers so log lines
        # written just after the error join it before delivery.
        @pending_window.hold(item)
      else
        deliver_item(item)
      end
    rescue StandardError => e
      @config.logger&.warn("[postdeploy] capture failed internally; event dropped: #{e.class}: #{e.message}")
    end

    def scrub_item(item)
      fields = Scrubber::DEFAULT_SCRUB_FIELDS | Array(@config.scrub_fields)
      Scrubber.scrub(item, fields)
    end

    def deliver_item(item)
      # Scrub at the final item-to-envelope boundary as PendingWindow may have
      # appended breadcrumbs after the capture-time scrub.
      item = scrub_item(item)
      envelope = Envelope.wrap(config: @config, item: item)

      if @config.test_mode
        @transport.send_envelope(envelope)
      else
        @worker.enqueue(envelope)
      end
    rescue StandardError => e
      @config.logger&.warn("[postdeploy] delivery failed internally; event dropped: #{e.class}: #{e.message}")
    end

    # Exception class name, or the name of any ancestor, matches
    # `config.excluded_exceptions`. Never raises: an internal error (e.g. a
    # weird `class.name` override) is treated as "not excluded" so a
    # scrubbing bug in this check can never silently swallow a real error.
    def excluded?(exception)
      names = @config.excluded_exceptions
      return false if names.nil? || names.empty?

      exception.class.ancestors.any? { |ancestor| names.include?(ancestor.name) }
    rescue StandardError
      false
    end

    # `config.before_send` runs AFTER the built-in scrubber (`Scrubber`),
    # so a custom callback still sees redacted secrets, not raw ones. A
    # raising callback must never break capture: on error, the ORIGINAL
    # (already-scrubbed) item is sent instead of the callback's output.
    def apply_before_send(item)
      callback = @config.before_send
      return item unless callback

      begin
        callback.call(item)
      rescue StandardError => e
        @config.logger&.warn("[postdeploy] before_send raised; sending original event: #{e.class}: #{e.message}")
        item
      end
    end
  end
end
