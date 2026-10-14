# frozen_string_literal: true

require "spec_helper"
require "rails"
require "action_controller/railtie"
require "active_job/railtie"
require "rack/test"
require "logger"

# Force-load the railtie now that `::Rails::Railtie` exists. `lib/postdeploy.rb`
# only requires it conditionally at `postdeploy.rb` load time (spec_helper.rb
# requires "postdeploy" before this file requires "rails"), matching how a real
# host app's Gemfile order determines it — see railtie.rb's own comment.
require_relative "../../lib/postdeploy/railtie"

RSpec.describe "PostDeploy Rails auto-capture", :aggregate_failures do
  include Rack::Test::Methods

  # A `Rails::Application` can only be initialized once per process
  # (`initialize!` is not idempotent), so the whole app + routes + a
  # controller that raises are built exactly once here and reused by every
  # example in this file via Rack::Test against the REAL middleware stack
  # (`ActionDispatch::ShowExceptions` included) — the only way to actually
  # prove `PostDeploy::RackMiddleware`'s position, not just its class in
  # isolation.
  before(:all) do
    unless defined?(RailtieSpecController)
      Object.const_set(:RailtieSpecController, Class.new(ActionController::Base) do
        def boom
          raise "boom from the controller"
        end

        def ok
          render plain: "ok"
        end
      end)

      app_class = Class.new(Rails::Application) do
        config.eager_load = false
        config.secret_key_base = "railtie_spec_test_secret_key_base_0123456789"
        config.hosts.clear
        config.logger = Logger.new(IO::NULL)
        config.active_job.queue_adapter = :inline
        # GlobalID (pulled in by ActiveJob) rejects a blank/anonymous app
        # name; this test app has none, so set one explicitly.
        config.global_id.app = "postdeploy_railtie_spec"
        config.action_dispatch.show_exceptions = :all
        # Development-like: `DebugExceptions` renders the developer error page
        # and does NOT re-raise. This is the scenario that silently dropped
        # unhandled web errors when the middleware sat outside
        # `DebugExceptions` — the regression this spec now guards.
        config.consider_all_requests_local = true

        routes.append do
          get "/boom", to: "railtie_spec#boom"
          get "/ok", to: "railtie_spec#ok"
        end
      end
      app_class.initialize!
    end

    # spec_helper.rb's global `before(:each)` hook calls `PostDeploy.reset!`
    # (needed so every OTHER spec file starts from a clean configuration),
    # which would also wipe the `app_dirs` the railtie sets here — capture
    # it once, at boot, the same way a real Rails app's initializer runs
    # exactly once and is never re-applied per request.
    @railtie_detected_app_dirs = PostDeploy.configuration.app_dirs.dup
  end

  def app
    Rails.application
  end

  before do
    # `PostDeploy.configure` only clears the memoized client (giving each
    # example a fresh `TestTransport`/empty `envelopes`) — NOT the full
    # `PostDeploy.reset!`, which would also wipe `config.app_dirs`, the one
    # thing the railtie's `initializer` sets exactly once at app boot
    # (`before(:all)` above), same as a real Rails app never re-runs its
    # initializers per request.
    PostDeploy.configure do |c|
      c.key = "alp_p_test_key"
      c.test_mode = true
    end
  end

  it "installs PostDeploy::RackMiddleware inside ActionDispatch::DebugExceptions" do
    stack = Rails.application.middleware.map(&:klass)
    debug_exceptions_index = stack.index(ActionDispatch::DebugExceptions)
    postdeploy_index = stack.index(PostDeploy::RackMiddleware)

    expect(debug_exceptions_index).not_to be_nil
    expect(postdeploy_index).not_to be_nil
    # Inside DebugExceptions (higher index = closer to the app), so the
    # developer error page never swallows the exception before we capture it.
    expect(postdeploy_index).to be > debug_exceptions_index
  end

  it "captures an unhandled exception raised by a controller action, with the app still returning its normal error response" do
    get "/boom"

    expect(last_response.status).to eq(500)
    expect(PostDeploy.test_transport.envelopes.length).to eq(1)
    item = PostDeploy.test_transport.envelopes.first[:items].first
    expect(item[:exception][:type]).to eq("RuntimeError")
    expect(item[:exception][:value]).to eq("boom from the controller")
    expect(item[:mechanism]).to eq("rack.middleware")
  end

  it "captures nothing for a request that does not raise" do
    get "/ok"

    expect(last_response.status).to eq(200)
    expect(last_response.body).to eq("ok")
    expect(PostDeploy.test_transport.envelopes).to be_empty
  end

  it "sets app_dirs from Rails.root so controller frames are in_app" do
    expect(@railtie_detected_app_dirs).to eq([Rails.root.to_s])
  end

  # Guards the require-order regression: `ActiveJob::Base` autoloads only
  # after boot, so the `defined?` check in `postdeploy.rb` is false at gem-load
  # time. The Railtie must (re-)install via `ActiveSupport.on_load(:active_job)`
  # so a real Rails app still gets job capture.
  it "installs the ActiveJob integration via the Railtie's on_load hook" do
    expect(ActiveJob::Base.ancestors).to include(PostDeploy::ActiveJob::ErrorReporting)
  end

  it "captures a raising ActiveJob and re-raises so retries still run" do
    job_class = Class.new(ActiveJob::Base) do
      def perform
        raise "boom from a job"
      end
    end

    expect { job_class.perform_now }.to raise_error("boom from a job")

    item = PostDeploy.test_transport.envelopes.last[:items].first
    expect(item[:mechanism]).to eq("active_job")
    expect(item[:exception][:value]).to eq("boom from a job")
  end
end
