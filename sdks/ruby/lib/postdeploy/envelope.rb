# frozen_string_literal: true

require "json"
require "time"

module PostDeploy
  # Builds the `POST /e/errors` wire envelope. Mirrors
  # `packages/sdk/src/core/observe/{client,envelope}.ts` (the TypeScript
  # SDK) and the Elixir SDK (#13): `{header: {key, sdk, sent_at}, items: [...]}`
  # with one item per request. Kept additive-only per docs/BUILD.md §5 —
  # every field here already exists in the accepted server shape.
  #
  # Per-field caps mirror the JS SDK's own write-boundary caps
  # (`envelope.ts`'s `MAX_*` constants) so an oversized field is trimmed
  # HERE, per field, and the event still sends — the same trade-off the JS
  # SDK makes. `Transport::MAX_ENVELOPE_BYTES`'s whole-envelope check stays
  # a last-resort safety net for the case these per-field caps still don't
  # fit (should be unreachable in practice, same as the JS SDK's own
  # comment on its equivalent guard).
  module Envelope
    MAX_ENVELOPE_BYTES = 1_048_576
    MAX_MESSAGE_CHARS = 4_096
    MAX_EXCEPTION_VALUE_CHARS = 4_096
    MAX_STACK_TRACE_CHARS = 16_384
    MAX_CONTEXT_CHARS = 8_192
    MAX_TAGS_CHARS = 4_096
    SERVER_MAX_BREADCRUMBS = 100
    MAX_BREADCRUMB_MESSAGE_CHARS = 2_048
    MAX_BREADCRUMB_CATEGORY_CHARS = 128
    # The server's `errorItemSchema.user` is `.strict()` with only `id`/
    # `email` (packages/schemas/src/observe/error-envelope.ts) — an
    # unrecognized key rejects the whole item, so `cap_user` below picks
    # only these two rather than forwarding an arbitrary hash. The JS SDK
    # passes `user` through uncapped (no `MAX_USER_*` there); this cap is
    # an SDK-side addition for the same defensive-write-boundary discipline
    # every other free-text field already gets here.
    MAX_USER_FIELD_CHARS = 256
    # Mirrors the server's `errorItemSchema.fingerprint`
    # (`z.array(z.string().max(256)).min(1).max(16)`, issue #17).
    MAX_FINGERPRINT_ENTRIES = 16
    MAX_FINGERPRINT_CHARS = 256
    # The server accepts an exception `cause` chain up to depth 5 counting
    # the top-level exception (`Alplus.Observe.ErrorEnvelope`); walk at most
    # 4 causes so a cyclic or absurd chain can never build an over-deep item.
    MAX_CAUSE_DEPTH = 4

    module_function

    def wrap(config:, item:)
      {
        header: {
          key: config.key,
          sdk: { name: PostDeploy::SDK_NAME, version: PostDeploy::VERSION, platform: "ruby" },
          sent_at: Time.now.utc.iso8601
        },
        items: [item]
      }
    end

    # Builds a `POST /e/sessions` wire item (issue #12) from an
    # `PostDeploy::Session`. Carries no PII: `session.id` is opaque and used
    # server-side only for in-window ingest dedup, then discarded (never
    # stored raw) — matching `Alplus.Observe.SessionEnvelope`, the server
    # parser.
    def session_item(session:, config:)
      {
        id: session.id,
        status: session.status.to_s,
        release: config.release,
        environment: config.environment
      }.compact
    end

    # `frames:` overrides the normal `Stack.frames_for(exception, ...)`
    # capture with an already-built wire frame array, for callers that
    # already have wire-shaped frames (mirrors the Elixir SDK's
    # `Envelope.build_frame(%{} = wire_frame, _)` passthrough). Real capture
    # callers never pass this; it exists so the golden-envelope contract
    # spec (issue #18) can call this REAL function with the golden's
    # literal, cross-language-reproducible frames instead of a real
    # backtrace tied to one language's stack-trace format.
    def exception_item(id:, exception:, config:, level: "error", context: nil, contexts: nil, tags: nil, breadcrumbs: nil, user: nil, mechanism: "generic", fingerprint: nil, frames: nil)
      frames ||= Stack.frames_for(exception, app_dirs: config.app_dirs, context_lines: config.context_lines.to_i)
      exc = { type: exception.class.name, value: cap_text(exception.message.to_s, MAX_EXCEPTION_VALUE_CHARS) }
      capped_frames = cap_frames(frames, MAX_STACK_TRACE_CHARS)
      exc[:stacktrace] = { frames: capped_frames } unless capped_frames.empty?
      cause = build_cause(exception.cause, config, MAX_CAUSE_DEPTH)
      exc[:cause] = cause if cause

      base_item(id: id, type: "exception", level: level, config: config, mechanism: mechanism, context: context, contexts: contexts, tags: tags, breadcrumbs: breadcrumbs, user: user, fingerprint: fingerprint)
        .merge(exception: exc)
    end

    # Walks `Exception#cause` into the wire `cause` chain (Honeybadger/
    # Sentry-style "caused by"). Each cause carries its own type, message,
    # and backtrace. Depth-bounded; a `cause` loop (possible via handwritten
    # `cause` overrides) terminates at the bound instead of hanging.
    def build_cause(exception, config, depth)
      return nil if exception.nil? || depth <= 0

      built = { type: exception.class.name, value: cap_text(exception.message.to_s, MAX_EXCEPTION_VALUE_CHARS) }
      frames = Stack.frames_for(exception, app_dirs: config.app_dirs, context_lines: config.context_lines.to_i)
      capped_frames = cap_frames(frames, MAX_STACK_TRACE_CHARS)
      built[:stacktrace] = { frames: capped_frames } unless capped_frames.empty?
      nested = build_cause(exception.cause, config, depth - 1)
      built[:cause] = nested if nested
      built
    end

    def message_item(id:, message:, config:, level: "info", context: nil, contexts: nil, tags: nil, breadcrumbs: nil, user: nil, mechanism: "generic", fingerprint: nil)
      base_item(id: id, type: "message", level: level, config: config, mechanism: mechanism, context: context, contexts: contexts, tags: tags, breadcrumbs: breadcrumbs, user: user, fingerprint: fingerprint)
        .merge(message: cap_text(message.to_s, MAX_MESSAGE_CHARS))
    end

    # `context:` is the free-text convenience that folds into
    # `contexts.extra` (and, per capture, always REPLACES whatever ambient
    # `extra` context the caller's scope carried — it does not deep-merge
    # with it); `contexts:` is the arbitrary named-map form. Both fold into
    # one `contexts` wire key, matching the JS SDK and fixing this SDK's
    # previous `context`-only shape (issue #17).
    def base_item(id:, type:, level:, config:, mechanism:, context:, contexts:, tags:, breadcrumbs:, user:, fingerprint:)
      item = {
        id: id,
        type: type,
        timestamp: Time.now.utc.iso8601,
        level: level.to_s,
        release: config.release,
        environment: config.environment,
        mechanism: mechanism
      }
      named_contexts = contexts ? contexts.dup : {}
      named_contexts[:extra] = context if context && !context.empty?
      item[:contexts] = cap_context(named_contexts, MAX_CONTEXT_CHARS) unless named_contexts.empty?
      capped_tags = cap_tags(tags, MAX_TAGS_CHARS)
      item[:tags] = capped_tags if capped_tags
      capped_crumbs = cap_breadcrumbs(breadcrumbs, SERVER_MAX_BREADCRUMBS)
      item[:breadcrumbs] = capped_crumbs if capped_crumbs && !capped_crumbs.empty?
      capped_user = cap_user(user)
      item[:user] = capped_user if capped_user
      capped_fingerprint = cap_fingerprint(fingerprint)
      item[:fingerprint] = capped_fingerprint if capped_fingerprint
      item.compact
    end

    # Truncates a string to at most `max_length` characters. Passes
    # non-strings through `#to_s` first; callers already do this, kept
    # defensive here since a truncated field is safer than a raise.
    def cap_text(value, max_length)
      value = value.to_s
      return value if value.length <= max_length

      value[0, max_length]
    end

    # Caps a JSON-ish hash by its serialized size. A value whose
    # serialization exceeds `max_chars` is REPLACED by a small truncation
    # marker rather than cut mid-string, mirroring the JS SDK's
    # `capContext` — a partial JSON string is unparseable, which is worse
    # than a shorter one.
    def cap_context(value, max_chars)
      serialized = JSON.generate(value)
      return value if serialized.bytesize <= max_chars

      { _truncated: true, _original_chars: serialized.bytesize }
    end

    # Drops the tags object entirely (with a debug-log warning) rather than
    # send a truncated `Hash` that would no longer round-trip as one — same
    # trade-off the JS SDK's `capTags` makes. Returns `nil` for a `nil`/
    # empty input so the caller can omit the key.
    def cap_tags(tags, max_chars)
      return nil if tags.nil? || tags.empty?
      return tags if JSON.generate(tags).bytesize <= max_chars

      nil
    end

    # Drops trailing frames until the serialized array fits `max_chars`,
    # mirroring the JS SDK's `capFrames`/the server's `capFramesToBudget`.
    #
    # Binary-searches the cut point (O(log n) `JSON.generate` calls)
    # instead of popping one frame and re-serializing the whole array per
    # pop (O(n) calls, each itself O(n)) — a deep recursive backtrace can
    # carry thousands of frames, where the naive approach is noticeably
    # slow.
    def cap_frames(frames, max_chars)
      return frames if frames.empty? || JSON.generate(frames).bytesize <= max_chars

      low = 0
      high = frames.length - 1
      while low < high
        mid = (low + high + 1) / 2
        if JSON.generate(frames.first(mid)).bytesize <= max_chars
          low = mid
        else
          high = mid - 1
        end
      end
      frames.first(low)
    end

    # Builds the wire `user` object: only `id`/`email` (accepts either
    # symbol or string keys from the caller), each length-capped, matching
    # the server's `.strict()` `errorItemSchema.user` — any other key would
    # get the whole item rejected, so unrecognized keys are dropped rather
    # than forwarded. Returns `nil` for a `nil`/empty input, or if neither
    # recognized key is present, so the caller can omit the wire key.
    def cap_user(user)
      return nil if user.nil? || user.empty?

      id = user[:id] || user["id"]
      email = user[:email] || user["email"]
      built = {}
      built[:id] = cap_text(id, MAX_USER_FIELD_CHARS) if id
      built[:email] = cap_text(email, MAX_USER_FIELD_CHARS) if email
      built.empty? ? nil : built
    end

    # Caps breadcrumb count to the server's own ceiling (keeping the most
    # recent ones) and per-breadcrumb message/category length.
    def cap_breadcrumbs(breadcrumbs, max_count)
      return nil if breadcrumbs.nil?

      breadcrumbs.last(max_count).map do |crumb|
        crumb = crumb.dup
        crumb[:message] = cap_text(crumb[:message], MAX_BREADCRUMB_MESSAGE_CHARS) if crumb[:message]
        crumb[:category] = cap_text(crumb[:category], MAX_BREADCRUMB_CATEGORY_CHARS) if crumb[:category]
        crumb
      end
    end

    # Caps the custom fingerprint override to the server's own bounds:
    # at most `MAX_FINGERPRINT_ENTRIES` entries, each at most
    # `MAX_FINGERPRINT_CHARS` characters. Returns `nil` for a `nil`/empty
    # input so the caller can omit the wire key.
    def cap_fingerprint(fingerprint)
      return nil if fingerprint.nil? || fingerprint.empty?

      fingerprint.first(MAX_FINGERPRINT_ENTRIES).map { |part| cap_text(part.to_s, MAX_FINGERPRINT_CHARS) }
    end
  end
end
