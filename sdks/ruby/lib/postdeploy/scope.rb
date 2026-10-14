# frozen_string_literal: true

module PostDeploy
  # Request-scoped ambient scope (issue #17): the server analog of the JS
  # SDK's browser `withScope`. `PostDeploy.set_user`/`set_tag`/`set_context`/
  # `add_breadcrumb` write to a scope that lives on `Thread.current`
  # (fiber-local storage in Ruby -- see `Thread#[]`), so a value set once at
  # the top of a request (`RackMiddleware`) applies to every capture inside
  # that request without threading it through every call site, and never
  # bleeds into a different request handled on a reused thread-pool thread.
  class Scope
    THREAD_KEY = :postdeploy_scope
    private_constant :THREAD_KEY

    # Server ceiling (`Envelope::SERVER_MAX_BREADCRUMBS`) -- kept as a
    # literal here rather than requiring `envelope` first (`Scope` loads
    # before `Envelope` in `postdeploy.rb`), and re-asserted by
    # `Envelope.cap_breadcrumbs` regardless.
    MAX_BREADCRUMBS = 100

    class << self
      # The current thread/fiber's scope, lazily created.
      def current
        Thread.current[THREAD_KEY] ||= new
      end

      # Replaces the current thread/fiber's scope with a fresh, empty one
      # and yields; restores whatever scope (if any) was active before,
      # even if the block raises. `RackMiddleware` wraps each request in
      # this so scope set during request A never leaks into request B on a
      # reused thread-pool thread.
      def with_clean_scope
        previous = Thread.current[THREAD_KEY]
        Thread.current[THREAD_KEY] = new
        yield
      ensure
        Thread.current[THREAD_KEY] = previous
      end
    end

    attr_reader :user, :tags, :contexts, :breadcrumbs

    def initialize
      @user = nil
      @tags = {}
      @contexts = {}
      @breadcrumbs = []
    end

    def set_user(user)
      @user = user
    end

    def set_tag(key, value)
      @tags[key.to_s] = value.to_s
    end

    def set_context(name, data)
      @contexts[name.to_s] = data
    end

    # `breadcrumb` accepts the same keys as the wire shape
    # (`message`/`category`/`level`/`data`/`ts`); `ts` defaults to now.
    # Bounded ring buffer: the oldest breadcrumb is dropped once the buffer
    # is at `MAX_BREADCRUMBS`.
    def add_breadcrumb(message: nil, category: nil, level: nil, data: nil, ts: nil)
      crumb = { message: message, category: category, level: level, data: data, ts: ts || Time.now.utc.iso8601 }.compact
      @breadcrumbs << crumb
      @breadcrumbs.shift while @breadcrumbs.length > MAX_BREADCRUMBS
    end

    # Immutable snapshot handed to `Client` at capture time — mirrors the
    # JS SDK's `ScopeSnapshot` (`scope.ts`).
    def snapshot
      { user: @user, tags: @tags.dup, contexts: @contexts.dup, breadcrumbs: @breadcrumbs.dup }
    end
  end

  # Merges an ambient `Scope#snapshot` with per-capture overrides. Mirrors
  # `packages/sdk/src/core/observe/scope.ts`'s `mergeScope`: an explicit
  # per-call `user:` wins outright over the ambient one; `tags`/`contexts`
  # shallow-merge with the override's keys winning on collision;
  # breadcrumbs concatenate (ambient trail first, then any one-off
  # breadcrumbs passed for this one call).
  #
  # `user:` distinguishes "not given" from "explicitly `nil`" via the
  # `PostDeploy::UNSET` sentinel default, mirroring the JS SDK's
  # `overrides.user !== undefined` check: `Client` passes `PostDeploy::UNSET`
  # through when its own `user:` param wasn't given by the caller, so a
  # caller CAN pass `user: nil` to clear the ambient user for one capture
  # rather than always falling back to it.
  module ScopeMerge
    module_function

    def merge(ambient:, user:, tags:, contexts:, breadcrumbs:)
      {
        user: user.equal?(PostDeploy::UNSET) ? ambient[:user] : user,
        tags: ambient[:tags].merge(tags || {}),
        contexts: ambient[:contexts].merge(contexts || {}),
        breadcrumbs: ambient[:breadcrumbs] + (breadcrumbs || [])
      }
    end
  end
end
