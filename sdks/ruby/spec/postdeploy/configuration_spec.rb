# frozen_string_literal: true

require "spec_helper"

RSpec.describe PostDeploy::Configuration do
  it "is valid when enabled and a key is present" do
    config = described_class.new
    config.key = "alp_p_test"
    config.enabled = true
    expect(config).to be_valid
  end

  it "is invalid without a key" do
    config = described_class.new
    config.key = "  "
    expect(config).not_to be_valid
  end

  it "is invalid when disabled even with a key" do
    config = described_class.new
    config.key = "alp_p_test"
    config.enabled = false
    expect(config).not_to be_valid
  end

  it "always samples when sample_rate is 1.0" do
    config = described_class.new
    config.sample_rate = 1.0
    expect(config.sampled?).to be true
  end

  it "never samples when sample_rate is 0.0" do
    config = described_class.new
    config.sample_rate = 0.0
    expect(config.sampled?).to be false
  end

  it "resolves the post-error window to 0 in test mode" do
    config = described_class.new
    config.test_mode = true
    config.post_error_log_window_ms = nil
    expect(config.resolved_post_error_log_window_ms).to eq(0)
  end

  it "resolves the post-error window to 2000 ms outside test mode" do
    config = described_class.new
    config.test_mode = false
    config.post_error_log_window_ms = nil
    expect(config.resolved_post_error_log_window_ms).to eq(2_000)
  end

  it "honors an explicit post-error window" do
    config = described_class.new
    config.post_error_log_window_ms = 750
    expect(config.resolved_post_error_log_window_ms).to eq(750)
  end

  it "defaults the endpoint to ingest.postdeploy.dev" do
    config = described_class.new
    expect(config.endpoint).to eq("https://ingest.postdeploy.dev")
  end

  it "defaults context_lines to 3" do
    expect(described_class.new.context_lines).to eq(3)
  end

  it "copies the default scrub field list" do
    expect(described_class.new.scrub_fields).to include("password", "token")
  end
end
