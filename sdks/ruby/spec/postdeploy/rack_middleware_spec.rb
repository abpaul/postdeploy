# frozen_string_literal: true

require "spec_helper"

RSpec.describe PostDeploy::RackMiddleware do
  before do
    PostDeploy.configure { |c| c.test_mode = true }
  end

  it "captures an exception raised by the wrapped app and re-raises it" do
    raising_app = ->(_env) { raise "boom from the app" }
    middleware = described_class.new(raising_app)

    expect { middleware.call({}) }.to raise_error(RuntimeError, "boom from the app")

    expect(PostDeploy.test_transport.envelopes.length).to eq(1)
    item = PostDeploy.test_transport.envelopes.first[:items].first
    expect(item[:exception][:type]).to eq("RuntimeError")
    expect(item[:mechanism]).to eq("rack.middleware")
  end

  it "passes through untouched when the app does not raise" do
    ok_app = ->(env) { [200, {}, ["ok: #{env["PATH_INFO"]}"]] }
    middleware = described_class.new(ok_app)

    status, _headers, body = middleware.call("PATH_INFO" => "/widgets")

    expect(status).to eq(200)
    expect(body).to eq(["ok: /widgets"])
    expect(PostDeploy.test_transport.envelopes).to be_empty
  end

  it "does not capture a process-control exception like SystemExit" do
    exiting_app = ->(_env) { raise SystemExit }
    middleware = described_class.new(exiting_app)

    expect { middleware.call({}) }.to raise_error(SystemExit)
    expect(PostDeploy.test_transport.envelopes).to be_empty
  end

  describe "session lifecycle (issue #12)" do
    after { Thread.current[:postdeploy_session] = nil }

    it "reports a healthy session when the app completes without a captured error" do
      ok_app = ->(_env) { [200, {}, ["ok"]] }
      middleware = described_class.new(ok_app)

      middleware.call({})

      expect(PostDeploy.test_transport.session_envelopes.length).to eq(1)
      item = PostDeploy.test_transport.session_envelopes.first[:items].first
      expect(item[:status]).to eq("healthy")
      expect(item[:id]).to start_with("ses_")
      expect(Thread.current[:postdeploy_session]).to be_nil
    end

    it "reports an errored session when a handled error is captured during the request" do
      app = lambda { |_env|
        PostDeploy.capture_exception(RuntimeError.new("handled"))
        [200, {}, ["ok"]]
      }
      middleware = described_class.new(app)

      middleware.call({})

      item = PostDeploy.test_transport.session_envelopes.first[:items].first
      expect(item[:status]).to eq("errored")
    end

    it "reports a crashed session, not merely errored, when the app raises unhandled" do
      raising_app = ->(_env) { raise "boom from the app" }
      middleware = described_class.new(raising_app)

      expect { middleware.call({}) }.to raise_error(RuntimeError)

      item = PostDeploy.test_transport.session_envelopes.first[:items].first
      expect(item[:status]).to eq("crashed")
    end

    it "does not leak a session from one request into the next on a reused thread" do
      call_count = 0
      seen_session_in_second_request = :not_checked
      app = lambda { |_env|
        call_count += 1
        seen_session_in_second_request = PostDeploy::Session.current.status if call_count == 2
        [200, {}, ["ok"]]
      }
      middleware = described_class.new(app)

      middleware.call({}) # request one: healthy session closes and clears
      middleware.call({}) # request two: must start fresh, not see request one's closed session

      expect(seen_session_in_second_request).to eq(:healthy)
    end
  end

  describe "scope isolation across requests on a reused thread (issue #17)" do
    after { Thread.current[:postdeploy_scope] = nil }

    it "does not leak PostDeploy.set_user from one request into the next on the same thread" do
      seen_user_in_second_request = :not_set
      call_count = 0
      app = lambda { |_env|
        call_count += 1
        if call_count == 1
          PostDeploy.set_user(id: "request-one")
        else
          seen_user_in_second_request = PostDeploy::Scope.current.snapshot[:user]
        end
        [200, {}, ["ok"]]
      }
      middleware = described_class.new(app)

      middleware.call({}) # request one: sets a user
      middleware.call({}) # request two, same thread: must start with no user

      expect(seen_user_in_second_request).to be_nil
    end

    it "the scope is empty at the start of a fresh request" do
      seen_user = nil
      app = lambda { |_env|
        seen_user = PostDeploy::Scope.current.snapshot[:user]
        [200, {}, ["ok"]]
      }
      middleware = described_class.new(app)

      PostDeploy::Scope.current.set_user(id: "leftover-from-outside-any-request")
      middleware.call({})

      expect(seen_user).to be_nil
    end
  end

  describe "request context" do
    require "rack"

    def env_for(path, query: "", method: "GET", extra: {})
      {
        "REQUEST_METHOD" => method,
        "PATH_INFO" => path,
        "QUERY_STRING" => query,
        "SERVER_NAME" => "app.example",
        "SERVER_PORT" => "443",
        "rack.url_scheme" => "https",
        "rack.input" => StringIO.new("")
      }.merge(extra)
    end

    it "attaches method, query-stripped url, params, and allowlisted headers to a capture" do
      raising_app = ->(_env) { raise "boom" }
      middleware = described_class.new(raising_app)

      # Concatenated at runtime: a plain literal would also appear in this
      # spec file's own source lines, which the frames' source context
      # legitimately captures, and the not-leaked assertion below would
      # false-positive on it.
      cookie_value = ["hidden", "cookie", "value"].join("-")
      bearer_value = ["hidden", "bearer", "value"].join("-")

      env = env_for("/orders", query: "coupon=SAVE10", extra: {
                      "HTTP_USER_AGENT" => "TestBrowser/1.0",
                      "HTTP_COOKIE" => "session=#{cookie_value}",
                      "HTTP_AUTHORIZATION" => "Bearer #{bearer_value}"
                    })

      expect { middleware.call(env) }.to raise_error(RuntimeError)

      item = PostDeploy.test_transport.envelopes.first[:items].first
      request = item[:contexts]["request"]
      expect(request[:method]).to eq("GET")
      expect(request[:url]).to eq("https://app.example/orders")
      expect(request[:url]).not_to include("coupon")
      expect(request[:params]).to eq("coupon" => "SAVE10")
      expect(request[:headers]).to eq("User-Agent" => "TestBrowser/1.0")
      expect(JSON.generate(item)).not_to include(cookie_value, bearer_value)
    end

    it "merges form params and scrubs secret-keyed values before send" do
      raising_app = ->(_env) { raise "boom" }
      middleware = described_class.new(raising_app)

      body = "password=hunter2&note=hello"
      env = env_for("/login", method: "POST", extra: {
                      "CONTENT_TYPE" => "application/x-www-form-urlencoded",
                      "CONTENT_LENGTH" => body.bytesize.to_s,
                      "rack.input" => StringIO.new(body)
                    })

      expect { middleware.call(env) }.to raise_error(RuntimeError)

      item = PostDeploy.test_transport.envelopes.first[:items].first
      params = item[:contexts]["request"][:params]
      expect(params["note"]).to eq("hello")
      expect(params["password"]).to eq("[FILTERED]")
    end

    it "captures without request context when the env is not a real Rack env" do
      raising_app = ->(_env) { raise "boom" }
      middleware = described_class.new(raising_app)

      expect { middleware.call({}) }.to raise_error(RuntimeError)

      item = PostDeploy.test_transport.envelopes.first[:items].first
      expect(item[:exception][:type]).to eq("RuntimeError")
    end
  end
end
