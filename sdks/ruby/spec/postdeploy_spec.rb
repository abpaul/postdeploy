# frozen_string_literal: true

require "spec_helper"

RSpec.describe PostDeploy do
  before { described_class.configure { |c| c.test_mode = true } }

  describe ".configure" do
    it "yields the shared configuration and rebuilds the client on the next access" do
      described_class.configure { |c| c.release = "v2.0.0" }
      expect(described_class.configuration.release).to eq("v2.0.0")
    end
  end

  describe ".capture_exception" do
    it "returns an err_-prefixed id and records the envelope" do
      id = described_class.capture_exception(RuntimeError.new("boom"))
      expect(id).to start_with("err_")
      expect(described_class.test_transport.envelopes.length).to eq(1)
    end

    it "never raises even if the exception argument is not an Exception" do
      expect { described_class.capture_exception("not an exception") }.not_to raise_error
    end

    it "forwards user: onto the wire item" do
      described_class.capture_exception(RuntimeError.new("boom"), user: { id: "user_1", email: "a@b.com" })
      expect(described_class.test_transport.envelopes.first[:items].first[:user]).to eq(id: "user_1", email: "a@b.com")
    end
  end

  describe ".capture_message" do
    it "returns an err_-prefixed id and records a message-type item" do
      id = described_class.capture_message("something happened", level: "warning")
      expect(id).to start_with("err_")
      expect(described_class.test_transport.envelopes.first[:items].first[:level]).to eq("warning")
    end
  end

  describe "the ingest key" do
    it "never appears in Configuration#inspect or #to_s" do
      described_class.configure { |c| c.key = "alp_p_super_secret_value" }
      expect(described_class.configuration.inspect).not_to include("alp_p_super_secret_value")
      expect(described_class.configuration.to_s).not_to include("alp_p_super_secret_value")
    end
  end

  describe ".flush" do
    it "returns true and never raises when nothing is queued" do
      expect(described_class.flush(timeout: 1)).to be true
    end

    it "never raises when the client is broken" do
      allow(described_class).to receive(:client).and_raise(RuntimeError, "down")
      expect(described_class.flush).to be false
    end
  end

  describe "request-scoped setters" do
    it "set_user, set_tag, set_context, and add_breadcrumb attach to the next capture" do
      described_class.set_user(id: "u1", email: "a@b.com")
      described_class.set_tag("plan", "indie")
      described_class.set_context("device", { os: "mac" })
      described_class.add_breadcrumb(message: "opened cart", category: "nav")
      described_class.capture_message("hi")
      described_class.flush

      item = described_class.test_transport.envelopes.first[:items].first
      expect(item[:user]).to include(id: "u1", email: "a@b.com")
      expect(item[:tags]).to include("plan" => "indie")
      expect(item[:contexts]["device"] || item[:contexts][:device]).to include(os: "mac")
      expect(item[:breadcrumbs].first[:message]).to eq("opened cart")
    end

    it "setters never raise on bad input" do
      expect(described_class.set_user(Object.new)).to be_nil
      expect(described_class.set_tag(nil, nil)).to be_nil
      expect(described_class.set_context(nil, "not-a-hash")).to be_nil
      expect(described_class.add_breadcrumb).to be_nil
    end
  end

  describe ".heartbeat" do
    it "never raises and returns nil" do
      stub_request(:post, %r{\Ahttps://ingest\.postdeploy\.dev/h/}).to_return(status: 202)
      expect(described_class.heartbeat("hb_x")).to be_nil
      expect(described_class.heartbeat("hb_x", state: "fail")).to be_nil
    end
  end

  describe ".close_session" do
    it "is a no-op when no session is open" do
      expect(described_class.close_session).to be_nil
    end

    it "reports the current session when one is open" do
      PostDeploy::Session.with_clean_session do
        expect(described_class.close_session).to be_nil
      end
      described_class.flush
      expect(described_class.test_transport.session_envelopes).not_to be_empty
    end
  end

  describe ".initialized_client" do
    it "is nil until the first capture constructs a client" do
      described_class.reset!
      expect(described_class.initialized_client).to be_nil
      described_class.configure { |c| c.test_mode = true; c.key = "alp_p_test_key" }
      described_class.capture_message("hi")
      expect(described_class.initialized_client).not_to be_nil
    end
  end
end
