# frozen_string_literal: true

require "spec_helper"

RSpec.describe "before_send hook, PII scrubbing, and excluded_exceptions" do
  let(:config) do
    PostDeploy::Configuration.new.tap do |c|
      c.key = "alp_p_test_key"
      c.test_mode = true
    end
  end
  let(:client) { PostDeploy::Client.new(config) }

  describe "config.before_send" do
    it "drops the event entirely when the callback returns nil" do
      config.before_send = ->(_item) { nil }

      client.capture_exception(RuntimeError.new("boom"))

      expect(client.transport.envelopes).to be_empty
    end

    it "sends the callback's modified item when it returns a hash" do
      config.before_send = lambda { |item|
        item.merge(tags: (item[:tags] || {}).merge("scrubbed_by" => "before_send"))
      }

      client.capture_exception(RuntimeError.new("boom"))
      item = client.transport.envelopes.first[:items].first

      expect(item[:tags]).to eq("scrubbed_by" => "before_send")
    end

    it "scrubs sensitive fields added by the callback" do
      config.before_send = lambda { |item|
        item.merge(contexts: { request: { Password: "secret", nested: [{ api_key: "key" }] } })
      }

      client.capture_exception(RuntimeError.new("boom"))
      item = client.transport.envelopes.first[:items].first

      expect(item[:contexts]).to eq(request: { Password: "[FILTERED]", nested: [{ api_key: "[FILTERED]" }] })
    end

    it "sends the original (scrubbed) item when the callback raises" do
      config.before_send = ->(_item) { raise "boom in before_send" }

      client.capture_exception(RuntimeError.new("boom"), context: { password: "hunter2" })
      item = client.transport.envelopes.first[:items].first

      expect(item[:exception][:type]).to eq("RuntimeError")
      expect(item[:contexts][:extra][:password]).to eq("[FILTERED]")
    end

    it "redacts a secret in a breadcrumb's data payload" do
      client.capture_exception(
        RuntimeError.new("boom"),
        breadcrumbs: [{ message: "user updated", category: "auth", data: { password: "hunter2", ok: "keep" } }]
      )
      crumb = client.transport.envelopes.first[:items].first[:breadcrumbs].first

      expect(crumb[:data][:password]).to eq("[FILTERED]")
      expect(crumb[:data][:ok]).to eq("keep")
    end

    it "receives the wire item hash, not the raw exception" do
      seen = nil
      config.before_send = lambda { |item|
        seen = item
        item
      }

      client.capture_exception(RuntimeError.new("boom"))

      expect(seen).to be_a(Hash)
      expect(seen[:type]).to eq("exception")
    end
  end

  describe "default PII scrubbing" do
    it "redacts a nested secret under context" do
      client.capture_exception(RuntimeError.new("boom"), context: { user: { password: "hunter2", name: "Ada" } })
      item = client.transport.envelopes.first[:items].first

      expect(item[:contexts][:extra][:user][:password]).to eq("[FILTERED]")
      expect(item[:contexts][:extra][:user][:name]).to eq("Ada")
    end

    it "redacts secrets nested inside arrays" do
      client.capture_exception(RuntimeError.new("boom"), context: { requests: [{ authorization: "Bearer xyz" }] })
      item = client.transport.envelopes.first[:items].first

      expect(item[:contexts][:extra][:requests].first[:authorization]).to eq("[FILTERED]")
    end

    it "matches sensitive keys case-insensitively" do
      client.capture_exception(RuntimeError.new("boom"), context: { "API_KEY" => "supersecret" })
      item = client.transport.envelopes.first[:items].first

      expect(item[:contexts][:extra]["API_KEY"]).to eq("[FILTERED]")
    end

    it "redacts a secret carried in tags" do
      client.capture_exception(RuntimeError.new("boom"), tags: { "csrf_token" => "abc123" })
      item = client.transport.envelopes.first[:items].first

      expect(item[:tags]["csrf_token"]).to eq("[FILTERED]")
    end

    it "adds custom scrub fields without weakening the mandatory defaults" do
      config.scrub_fields = ["internal_id"]

      client.capture_exception(RuntimeError.new("boom"), context: { password: "hunter2", internal_id: "42" })
      item = client.transport.envelopes.first[:items].first

      expect(item[:contexts][:extra][:password]).to eq("[FILTERED]")
      expect(item[:contexts][:extra][:internal_id]).to eq("[FILTERED]")
    end

    it "keeps mandatory defaults when custom scrub fields are empty" do
      config.scrub_fields = []

      client.capture_exception(RuntimeError.new("boom"), context: { password: "hunter2" })
      item = client.transport.envelopes.first[:items].first

      expect(item[:contexts][:extra][:password]).to eq("[FILTERED]")
    end
  end

  describe "config.excluded_exceptions" do
    it "defaults to empty, so nothing is excluded for a non-Rails host app" do
      expect(PostDeploy::Configuration.new.excluded_exceptions).to eq([])
    end

    it "skips capture for an excluded exception class, still returning an id" do
      config.excluded_exceptions = ["RuntimeError"]

      id = client.capture_exception(RuntimeError.new("boom"))

      expect(id).to start_with("err_")
      expect(client.transport.envelopes).to be_empty
    end

    it "skips capture when an ancestor class name matches" do
      custom_error_class = Class.new(RuntimeError)
      stub_const("PostDeploy::TestExcludedError", custom_error_class)
      config.excluded_exceptions = ["RuntimeError"]

      client.capture_exception(PostDeploy::TestExcludedError.new("boom"))

      expect(client.transport.envelopes).to be_empty
    end

    it "does not skip a class not in the excluded list" do
      config.excluded_exceptions = ["ActiveRecord::RecordNotFound"]

      client.capture_exception(RuntimeError.new("boom"))

      expect(client.transport.envelopes.length).to eq(1)
    end
  end
end
