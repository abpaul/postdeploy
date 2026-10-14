# frozen_string_literal: true

require "spec_helper"

RSpec.describe PostDeploy::Client do
  describe "async delivery (non-test-mode)" do
    let(:config) do
      PostDeploy::Configuration.new.tap do |c|
        c.key = "alp_p_test_key"
        c.endpoint = "https://ingest.example.test"
        # A retried send must never wait on real backoff wall-clock time in
        # a spec — `sleeper` is the injection point (issue #15 defect).
        c.sleeper = ->(_seconds) {}
      end
    end
    let(:client) { described_class.new(config) }

    it "never waits on real wall-clock time when a send is retried" do
      stub = stub_request(:post, "https://ingest.example.test/e/errors").to_return({ status: 503 }, { status: 202 })

      started_at = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      client.capture_exception(RuntimeError.new("boom"))
      client.flush(timeout: 2)
      elapsed = Process.clock_gettime(Process::CLOCK_MONOTONIC) - started_at

      expect(stub).to have_been_requested.times(2)
      expect(elapsed).to be < 1.0
    end

    it "accepts an explicit sleeper: constructor override, taking precedence over config.sleeper" do
      recorded = []
      config.sleeper = ->(_seconds) { raise "config.sleeper must not be used when an explicit override is given" }
      overridden_client = described_class.new(config, sleeper: ->(seconds) { recorded << seconds })
      stub_request(:post, "https://ingest.example.test/e/errors").to_return({ status: 503 }, { status: 202 })

      overridden_client.capture_exception(RuntimeError.new("boom"))
      overridden_client.flush(timeout: 2)

      expect(recorded.length).to eq(1)
    end

    it "sends the captured exception off the calling thread and flush waits for it" do
      stub = stub_request(:post, "https://ingest.example.test/e/errors").to_return(status: 202)

      id = client.capture_exception(RuntimeError.new("boom"))

      expect(id).to start_with("err_")
      expect(client.flush(timeout: 2)).to be true
      expect(stub).to have_been_requested.times(1)
    end

    it "swallows a transport failure without raising into the caller" do
      stub_request(:post, "https://ingest.example.test/e/errors").to_return(status: 500)

      expect { client.capture_exception(RuntimeError.new("boom")) }.not_to raise_error
      expect(client.flush(timeout: 2)).to be true
    end

    it "never raises or hangs the caller when captures outrun delivery" do
      # Deterministic drop behavior (queue-full → false, warning logged) is
      # covered at the `Worker` unit level in worker_spec.rb, where the
      # background thread is stubbed out so the queue state can't race the
      # assertion. Here we only assert the client-level contract: bursts of
      # captures never raise or block the calling thread.
      stub_request(:post, "https://ingest.example.test/e/errors").to_return(status: 202, body: "")

      expect do
        20.times { client.capture_exception(RuntimeError.new("boom")) }
      end.not_to raise_error

      # Drain before the example ends so the background thread never bleeds
      # a stray request into a later example's WebMock request history.
      client.flush(timeout: 2)
    end
  end

  describe "test mode" do
    let(:config) do
      PostDeploy::Configuration.new.tap do |c|
        c.key = "alp_p_test_key"
        c.test_mode = true
      end
    end
    let(:client) { described_class.new(config) }

    it "never touches the network" do
      client.capture_exception(RuntimeError.new("boom"))
      expect(a_request(:post, %r{/e/errors})).not_to have_been_made
    end

    it "records the envelope synchronously in the in-memory test transport" do
      client.capture_exception(RuntimeError.new("boom"))
      expect(client.transport.envelopes.length).to eq(1)
      expect(client.transport.envelopes.first[:items].first[:exception][:type]).to eq("RuntimeError")
    end

    it "attaches a user: to a captured exception" do
      client.capture_exception(RuntimeError.new("boom"), user: { id: "user_42", email: "dev@example.com" })
      item = client.transport.envelopes.first[:items].first
      expect(item[:user]).to eq(id: "user_42", email: "dev@example.com")
    end

    it "attaches a user: to a captured message" do
      client.capture_message("hello", user: { id: "user_7" })
      item = client.transport.envelopes.first[:items].first
      expect(item[:user]).to eq(id: "user_7")
    end

    it "attaches a fingerprint: override to a captured exception" do
      client.capture_exception(RuntimeError.new("boom"), fingerprint: %w[custom-group])
      item = client.transport.envelopes.first[:items].first
      expect(item[:fingerprint]).to eq(%w[custom-group])
    end

    it "merges a named contexts: map alongside context:" do
      client.capture_message("hello", context: { order_id: 42 }, contexts: { runtime: { engine: "ruby" } })
      item = client.transport.envelopes.first[:items].first
      expect(item[:contexts]).to eq(extra: { order_id: 42 }, runtime: { engine: "ruby" })
    end

    describe "dedup (issue #15)" do
      before { PostDeploy::Dedup.reset! }

      it "captures the SAME exception object twice within the window as ONE event, same id" do
        error = RuntimeError.new("boom")

        first_id = client.capture_exception(error)
        second_id = client.capture_exception(error)

        expect(second_id).to eq(first_id)
        expect(client.transport.envelopes.length).to eq(1)
      end

      it "does not dedupe two distinct exception objects with the same message" do
        client.capture_exception(RuntimeError.new("boom"))
        client.capture_exception(RuntimeError.new("boom"))

        expect(client.transport.envelopes.length).to eq(2)
      end

      it "does not register a dedup slot for a sampled-out capture, so a later real capture of the SAME error still sends (issue #15 defect)" do
        error = RuntimeError.new("boom")
        sampled_out_config = PostDeploy::Configuration.new.tap do |c|
          c.key = "alp_p_test_key"
          c.test_mode = true
          c.sample_rate = 0.0 # never sampled in
        end
        sampled_out_client = described_class.new(sampled_out_config)

        sampled_out_client.capture_exception(error) # would-be dedup slot, but gated out first
        client.capture_exception(error) # a real client capturing the SAME error object

        expect(sampled_out_client.transport.envelopes).to be_empty
        expect(client.transport.envelopes.length).to eq(1)
      end

      it "does not register a dedup slot for a disabled capture" do
        error = RuntimeError.new("boom")
        disabled_config = PostDeploy::Configuration.new.tap do |c|
          c.key = "alp_p_test_key"
          c.test_mode = true
          c.enabled = false
        end
        disabled_client = described_class.new(disabled_config)

        disabled_client.capture_exception(error)
        client.capture_exception(error)

        expect(client.transport.envelopes.length).to eq(1)
      end
    end

    describe "ambient scope (issue #17)" do
      after { Thread.current[:postdeploy_scope] = nil }

      it "applies PostDeploy.set_user/set_tag/set_context/add_breadcrumb to a subsequent capture" do
        PostDeploy.set_user(id: "user_1")
        PostDeploy.set_tag("region", "eu")
        PostDeploy.set_context("request", { path: "/x" })
        PostDeploy.add_breadcrumb(message: "step 1", category: "nav")

        client.capture_exception(RuntimeError.new("boom"))
        item = client.transport.envelopes.first[:items].first

        expect(item[:user]).to eq(id: "user_1")
        expect(item[:tags]).to eq("region" => "eu")
        expect(item[:contexts]).to eq("request" => { path: "/x" })
        expect(item[:breadcrumbs].first[:message]).to eq("step 1")
      end

      it "lets an explicit per-call user: override the ambient scope's user" do
        PostDeploy.set_user(id: "ambient")

        client.capture_exception(RuntimeError.new("boom"), user: { id: "explicit" })
        item = client.transport.envelopes.first[:items].first

        expect(item[:user]).to eq(id: "explicit")
      end

      it "lets an explicit per-call user: nil clear the ambient scope's user (issue #17 defect)" do
        PostDeploy.set_user(id: "ambient")

        client.capture_exception(RuntimeError.new("boom"), user: nil)
        item = client.transport.envelopes.first[:items].first

        expect(item).not_to have_key(:user)
      end
    end
  end

  describe "#report_session (issue #12)" do
    let(:config) do
      PostDeploy::Configuration.new.tap do |c|
        c.key = "alp_p_test_key"
        c.test_mode = true
      end
    end
    let(:client) { described_class.new(config) }

    it "records the session envelope synchronously in the in-memory test transport" do
      session = PostDeploy::Session.new
      client.report_session(session)

      expect(client.transport.session_envelopes.length).to eq(1)
      expect(client.transport.envelopes).to be_empty
      item = client.transport.session_envelopes.first[:items].first
      expect(item[:id]).to eq(session.id)
      expect(item[:status]).to eq("healthy")
    end

    it "delivers a session while an /e/errors send is still stuck in flight (issue #12 fix)" do
      async_config = PostDeploy::Configuration.new.tap do |c|
        c.key = "alp_p_test_key"
        c.endpoint = "https://ingest.example.test"
        c.sleeper = ->(_seconds) {}
      end
      async_client = described_class.new(async_config)

      gate = Queue.new
      stub_request(:post, "https://ingest.example.test/e/errors").to_return do
        gate.pop # blocks the :error worker thread until released below
        { status: 202 }
      end
      session_received = Queue.new
      session_stub = stub_request(:post, "https://ingest.example.test/e/sessions").to_return do
        session_received.push(:received)
        { status: 202 }
      end

      async_client.capture_exception(RuntimeError.new("stuck")) # occupies the :error lane

      session = PostDeploy::Session.new
      enqueued = async_client.report_session(session)
      expect(enqueued).to be true # never blocks on the stuck :error lane

      expect(session_received.pop(timeout: 2)).to eq(:received)
      expect(session_stub).to have_been_requested.times(1)

      gate.push(:go) # release the stuck send so the example doesn't leak a hung thread
      async_client.flush(timeout: 2)
    end

    it "is a no-op when the config is invalid (no key)" do
      invalid_config = PostDeploy::Configuration.new.tap { |c| c.key = nil; c.test_mode = true }
      invalid_client = described_class.new(invalid_config)

      invalid_client.report_session(PostDeploy::Session.new)

      expect(invalid_client.transport.session_envelopes).to be_empty
    end
  end

  describe "the enabled flag" do
    let(:config) do
      PostDeploy::Configuration.new.tap do |c|
        c.key = "alp_p_test_key"
        c.test_mode = true
        c.enabled = false
      end
    end
    let(:client) { described_class.new(config) }

    it "returns an id but captures nothing when disabled" do
      id = client.capture_exception(RuntimeError.new("boom"))
      expect(id).to start_with("err_")
      expect(client.transport.envelopes).to be_empty
    end
  end

  describe "a missing ingest key" do
    let(:config) { PostDeploy::Configuration.new.tap { |c| c.key = nil; c.test_mode = true } }
    let(:client) { described_class.new(config) }

    it "returns an id but captures nothing" do
      id = client.capture_exception(RuntimeError.new("boom"))
      expect(id).to start_with("err_")
      expect(client.transport.envelopes).to be_empty
    end
  end
end
