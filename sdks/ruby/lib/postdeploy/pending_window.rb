# frozen_string_literal: true

module PostDeploy
  # The post-error log window (issue #47): a built exception item is held
  # here for a short, bounded window before delivery, and log-line
  # breadcrumbs recorded on the SAME thread during the window are appended
  # to it, marked `data: { after_error: true }`.
  #
  # Same-thread attribution is the correctness rule: under a concurrent
  # server, another request's log lines must never pollute this error's
  # timeline. Rails logs the unhandled exception (DebugExceptions) on the
  # request thread AFTER `RackMiddleware` re-raises, which is exactly the
  # window this class keeps open — a request-end seal would run too early
  # to see that line.
  #
  # One lazily-spawned sealer thread sleeps until the earliest deadline and
  # seals due entries; it exits when the list drains and respawns on the
  # next hold. `seal_all!` (called by `Client#flush`/`#close`) seals
  # everything immediately — the window delays delivery, never loses events.
  class PendingWindow
    MAX_AFTER_ERROR_BREADCRUMBS = 20
    # The server ceiling (`Envelope::SERVER_MAX_BREADCRUMBS`).
    MAX_TOTAL_BREADCRUMBS = Envelope::SERVER_MAX_BREADCRUMBS

    Entry = Struct.new(:item, :thread, :deadline, :appended, keyword_init: true)

    def initialize(window_ms, &deliver)
      @window_ms = window_ms
      @deliver = deliver
      @entries = []
      @mutex = Mutex.new
      @sealer = nil
    end

    def enabled?
      @window_ms.positive?
    end

    def hold(item)
      entry = Entry.new(item: item, thread: Thread.current, deadline: monotonic_now + (@window_ms / 1000.0), appended: 0)
      @mutex.synchronize { @entries << entry }
      ensure_sealer_running
    end

    # Appends a log-line breadcrumb to every pending entry captured on the
    # calling thread, within the per-entry and total bounds. Never raises.
    def notify_log_breadcrumb(crumb)
      @mutex.synchronize do
        @entries.each do |entry|
          next unless entry.thread == Thread.current
          next if entry.appended >= MAX_AFTER_ERROR_BREADCRUMBS

          crumbs = (entry.item[:breadcrumbs] ||= [])
          next if crumbs.length >= MAX_TOTAL_BREADCRUMBS

          crumbs << crumb.merge(data: (crumb[:data] || {}).merge(after_error: true))
          entry.appended += 1
        end
      end
      nil
    rescue StandardError
      nil
    end

    def seal_all!
      entries = @mutex.synchronize { @entries.slice!(0..) }
      entries.each { |entry| @deliver.call(entry.item) }
    end

    private

    def monotonic_now
      Process.clock_gettime(Process::CLOCK_MONOTONIC)
    end

    def ensure_sealer_running
      @mutex.synchronize do
        next if @sealer&.alive?

        @sealer = Thread.new { sealer_loop }
        @sealer.name = "postdeploy-pending-sealer" if @sealer.respond_to?(:name=)
      end
    end

    def sealer_loop
      loop do
        due, sleep_for = @mutex.synchronize do
          now = monotonic_now
          due_entries = @entries.select { |entry| entry.deadline <= now }
          @entries -= due_entries
          next_deadline = @entries.map(&:deadline).min
          [due_entries, next_deadline && (next_deadline - now)]
        end

        due.each { |entry| @deliver.call(entry.item) }
        break if sleep_for.nil?

        sleep([sleep_for, 0.01].max)
      end
    rescue StandardError
      # The sealer must never crash the host app; entries left behind are
      # still delivered by the next `seal_all!` (flush/close).
      nil
    end
  end
end
