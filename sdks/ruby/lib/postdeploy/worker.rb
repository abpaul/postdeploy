# frozen_string_literal: true

require "thread"

module PostDeploy
  # Background-thread sender with a bounded queue: `#enqueue` never blocks
  # the caller. When the queue is full, the event is dropped (non-
  # authoritative, matching the JS SDK's own batching drop behavior) rather
  # than applying backpressure to the request thread (issue #14 story 7/8).
  #
  # The worker thread is lazily started on first enqueue and is never
  # joined/killed explicitly: Ruby terminates all non-main threads when the
  # process exits, so there is nothing to supervise for a short-lived
  # script or a `Rack::Handler` process to leak.
  #
  # One `Worker` instance is ONE independent delivery lane: its own
  # `SizedQueue` and its own background thread, fixed to one `kind:`
  # (`:error` or `:session`) for its whole lifetime (issue #12 fix). A
  # PRIOR version routed both kinds through a single shared queue/thread —
  # a stalled or slow `/e/errors` POST (up to ~20s across
  # `Retry::MAX_ATTEMPTS` retries) head-of-line-blocked every queued
  # session behind it, and a full queue during an error storm silently
  # dropped the next session, exactly when crash-free data matters most.
  # `Client` now owns two `Worker`s so error backpressure can never delay
  # or drop session delivery, or vice versa.
  class Worker
    def initialize(config, transport, kind: :error)
      @config = config
      @transport = transport
      @kind = kind
      @queue = SizedQueue.new(config.max_queue_size)
      @mutex = Mutex.new
      @thread = nil
      # Outstanding work count: incremented (under `@mutex`) the moment an
      # envelope is successfully pushed, decremented only after
      # `Transport#send_envelope` returns. `SizedQueue#pop` removes an item
      # from the queue *before* the worker thread finishes sending it, so
      # `@queue.empty?` alone goes true while a send is still in flight —
      # a concurrent `#flush`/`#close` reading only queue emptiness would
      # return early (TOCTOU). Counting outstanding work instead of
      # sampling a flag set after pop closes that window: the increment
      # happens atomically with the enqueue that a caller already observed
      # succeeding, not after some later point the reader could race.
      @outstanding = 0
    end

    # Enqueues an envelope for background delivery on THIS worker's own
    # lane (its `kind:`, fixed at construction). Returns `true` if queued,
    # `false` if dropped because the queue is full. Never raises.
    def enqueue(envelope)
      @mutex.synchronize do
        @queue.push(envelope, true)
        @outstanding += 1
      end
      ensure_thread_started
      true
    rescue ThreadError
      @config.logger&.warn("[postdeploy] #{@kind} queue full (max #{@config.max_queue_size}); dropping event")
      false
    end

    # Blocks up to `timeout` seconds for the queue to drain and any
    # in-flight send to finish. Returns `true` if it drained in time,
    # `false` on timeout. Never raises.
    def flush(timeout: 2)
      deadline = Time.now + timeout
      sleep(0.01) while !idle? && Time.now < deadline
      idle?
    end

    def queue_size
      @queue.size
    end

    private

    def idle?
      @mutex.synchronize { @outstanding.zero? }
    end

    def ensure_thread_started
      return if @thread&.alive?

      @mutex.synchronize do
        next if @thread&.alive?

        @thread = Thread.new { run }
        @thread.abort_on_exception = false
        @thread.report_on_exception = false if @thread.respond_to?(:report_on_exception=)
      end
    end

    def run
      loop do
        envelope = @queue.pop
        begin
          @transport.send_envelope(envelope, kind: @kind)
        rescue StandardError => e
          @config.logger&.warn("[postdeploy] worker error: #{e.class}: #{e.message}")
        ensure
          @mutex.synchronize { @outstanding -= 1 }
        end
      end
    end
  end
end
