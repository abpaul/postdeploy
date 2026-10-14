# frozen_string_literal: true

module PostDeploy
  # Exception dedup (issue #15), mirroring
  # `packages/sdk/src/core/observe/dedup.ts`'s `resolveDedupId`: the same
  # error captured twice within a short window (auto-capture AND a manual
  # `capture_exception` for the same raised exception, e.g. the Rack
  # middleware re-raising into a Rails handler that also reports it)
  # produces ONE event, not two.
  #
  # The JS SDK keys identity-bearing errors in a `WeakMap` so a dedup entry
  # never outlives (or pins alive) the error object. Ruby's
  # `ObjectSpace::WeakMap` holds its VALUES weakly too (not just keys) with
  # no other strong referent to a plain dedup-entry object, so a value
  # stashed there is eligible for GC before the next lookup -- unusable for
  # this. Instead, the dedup entry is stashed directly on the error object
  # itself via a hidden instance variable: it lives and dies with the
  # exact same object, which is a stronger and simpler guarantee than a
  # WeakMap gives (zero separate table to leak or prune for this path).
  #
  # A raised String/Symbol/Number/boolean/nil can't hold an instance
  # variable (and has no reference identity worth keying on regardless --
  # two unrelated `"boom"` literals are different objects but the same
  # *error*), so those use a small bounded value-keyed Hash instead, same
  # split as the JS SDK's `isWeakKeyable`.
  module Dedup
    WINDOW_SECONDS = 2.0
    # Bounds the primitive-keyed fallback so a flood of distinct thrown
    # strings can't grow it unboundedly.
    VALUE_CACHE_MAX = 50
    VALUE_KEYABLE_CLASSES = [String, Symbol, Integer, Float, TrueClass, FalseClass, NilClass].freeze

    IVAR = :@__postdeploy_dedup_entry__
    private_constant :IVAR

    Entry = Struct.new(:id, :expires_at)

    @value_map = {}
    @mutex = Mutex.new

    class << self
      # Returns `{id:, duplicate:}` — the fresh id for a new error, or the
      # PREVIOUS capture's id (and `duplicate: true`) if `error` was
      # already captured within the window. Never raises: on any internal
      # failure (e.g. a frozen error object rejecting the ivar write),
      # treats it as a fresh, non-duplicate capture rather than risk
      # silently dropping a real error.
      def resolve(error, fresh_id)
        now = monotonic_now
        @mutex.synchronize do
          if value_keyable?(error)
            resolve_value_keyed(error, fresh_id, now)
          else
            resolve_identity_keyed(error, fresh_id, now)
          end
        end
      rescue StandardError
        { id: fresh_id, duplicate: false }
      end

      # Test-only: clears the value-keyed table between examples. The
      # identity path needs no reset — a fresh `Exception.new` each example
      # carries no leftover ivar.
      def reset!
        @mutex.synchronize { @value_map.clear }
      end

      private

      def resolve_identity_keyed(error, fresh_id, now)
        existing = error.instance_variable_defined?(IVAR) ? error.instance_variable_get(IVAR) : nil
        if existing && existing.expires_at > now
          { id: existing.id, duplicate: true }
        else
          error.instance_variable_set(IVAR, Entry.new(fresh_id, now + WINDOW_SECONDS))
          { id: fresh_id, duplicate: false }
        end
      end

      def resolve_value_keyed(error, fresh_id, now)
        prune_expired(now)
        key = value_key(error)
        existing = @value_map[key]
        if existing && existing.expires_at > now
          { id: existing.id, duplicate: true }
        else
          @value_map.delete(@value_map.keys.first) if @value_map.size >= VALUE_CACHE_MAX
          @value_map[key] = Entry.new(fresh_id, now + WINDOW_SECONDS)
          { id: fresh_id, duplicate: false }
        end
      end

      def prune_expired(now)
        @value_map.delete_if { |_key, entry| entry.expires_at <= now }
      end

      def value_keyable?(error)
        VALUE_KEYABLE_CLASSES.any? { |klass| error.is_a?(klass) }
      end

      def value_key(error)
        "#{error.class}:#{error.inspect}"
      end

      def monotonic_now
        Process.clock_gettime(Process::CLOCK_MONOTONIC)
      end
    end
  end
end
