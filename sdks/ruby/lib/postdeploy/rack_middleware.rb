# frozen_string_literal: true

require "json"

module PostDeploy
  # Rack middleware: captures any exception that propagates up through the
  # app, then re-raises so the host's own error page / handler still runs
  # unchanged. Installed automatically by the Rails railtie; usable directly
  # in a plain Rack app (`use PostDeploy::RackMiddleware`).
  #
  # Also resets `Scope` to a fresh, empty one for the duration of the
  # request (issue #17): a thread-pool server (Puma, Passenger) reuses OS
  # threads across requests, so without this a `set_user`/`set_tag` call in
  # request A would otherwise still be visible to request B if it happens
  # to land on the same thread.
  #
  # Session lifecycle (issue #12): opens a fresh request-scoped `Session`
  # (`Session.with_clean_session`, the same reused-thread guard as `Scope`
  # above) and closes it (`PostDeploy.close_session`) once `@app.call` returns
  # OR raises. Unlike `sdks/elixir/lib/post_deploy/plug.ex` (which cannot
  # rescue a downstream plug's exception — see that module's moduledoc),
  # Rack middleware genuinely wraps the rest of the stack in one method
  # call, so `rescue`/`ensure` here is the complete, reliable crash signal:
  # no separate telemetry hook is needed.
  class RackMiddleware
    def initialize(app)
      @app = app
    end

    def call(env)
      Scope.with_clean_scope { Session.with_clean_session { call_app(env) } }
    end

    private

    def call_app(env)
      attach_request_context(env)
      @app.call(env)
    rescue StandardError => e
      # StandardError only, deliberately: SystemExit/SignalException/
      # NoMemoryError are process-control exceptions, not app errors, and
      # must propagate untouched. `mark_crashed` runs BEFORE
      # `capture_exception` below: that call would otherwise mark the
      # session merely `:errored` (any `"error"`-level capture does), and
      # `:crashed` must win regardless of call order — `Session`'s
      # severity ordering makes this safe either way.
      Session.current&.mark_crashed
      PostDeploy.capture_exception(e, mechanism: "rack.middleware")
      raise
    ensure
      PostDeploy.close_session
    end

    # Response headers a triaging dev actually reads. Cookie and
    # Authorization are deliberately absent — they are secrets, not
    # diagnostics, and key-based scrubbing must not be the only line of
    # defense against them.
    HEADER_ALLOWLIST = {
      "HTTP_USER_AGENT" => "User-Agent",
      "HTTP_REFERER" => "Referer",
      "HTTP_ACCEPT" => "Accept",
      "CONTENT_TYPE" => "Content-Type",
      "HTTP_X_REQUEST_ID" => "X-Request-Id"
    }.freeze

    # Serialized params beyond this are replaced by a truncation marker so
    # one giant upload form cannot push the whole `contexts` object over
    # `Envelope::MAX_CONTEXT_CHARS` (which would replace ALL contexts).
    MAX_PARAMS_CHARS = 4_096

    # Attaches `contexts.request` (method, url without query string, parsed
    # params, allowlisted headers) to the request's fresh Scope, so every
    # capture during this request carries it. Params go through the built-in
    # `Scrubber` at capture time like any other context value. The raw query
    # string is never attached: a raw string cannot be key-scrubbed; the
    # parsed params hash can. Never raises — request context is diagnostics,
    # not a reason to break the request.
    def attach_request_context(env)
      request = ::Rack::Request.new(env)

      context = {
        method: request.request_method,
        url: "#{request.base_url}#{request.path}",
        params: bounded_params(request),
        headers: request_headers(env)
      }.compact

      Scope.current.set_context("request", context)
    rescue StandardError
      nil
    end

    def bounded_params(request)
      params = query_params(request).merge(form_params(request))
      return nil if params.empty?
      return { "_truncated" => true } if JSON.generate(params).bytesize > MAX_PARAMS_CHARS

      params
    rescue StandardError
      nil
    end

    def query_params(request)
      request.GET || {}
    rescue StandardError
      {}
    end

    # Form-encoded bodies only; `Rack::Request#POST` rewinds the input, so
    # the downstream app still reads the full body. A JSON body is not
    # parsed here — parsing it would mean buffering and re-encoding the
    # body on every request just in case an error happens later.
    def form_params(request)
      request.form_data? ? request.POST : {}
    rescue StandardError
      {}
    end

    def request_headers(env)
      headers = HEADER_ALLOWLIST.each_with_object({}) do |(rack_key, header), out|
        value = env[rack_key]
        out[header] = value.to_s if value
      end
      headers.empty? ? nil : headers
    end
  end
end
