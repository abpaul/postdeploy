# frozen_string_literal: true

require "spec_helper"
require_relative "../../lib/postdeploy/rails_error_subscriber"

RSpec.describe PostDeploy::RailsErrorSubscriber do
  before { PostDeploy.configure { |c| c.test_mode = true } }

  it "captures a handled report through the error reporter" do
    described_class.new.report(
      RuntimeError.new("handled boom"),
      handled: true,
      severity: :error,
      context: { controller: "orders" }
    )
    PostDeploy.flush

    item = PostDeploy::Testing.events.first
    expect(item[:exception][:value]).to eq("handled boom")
    expect(item[:mechanism]).to eq("rails.error_reporter")
    expect(item[:level]).to eq("error")
  end

  it "ignores an unhandled report so RackMiddleware stays the only unhandled path" do
    described_class.new.report(
      RuntimeError.new("unhandled boom"),
      handled: false,
      severity: :error,
      context: {}
    )
    PostDeploy.flush
    expect(PostDeploy::Testing.events).to be_empty
  end

  it "maps warning and info severities onto wire levels" do
    subscriber = described_class.new
    subscriber.report(RuntimeError.new("warn"), handled: true, severity: :warning, context: {})
    subscriber.report(RuntimeError.new("info"), handled: true, severity: :info, context: {})
    PostDeploy.flush

    levels = PostDeploy::Testing.events.map { |item| item[:level] }
    expect(levels).to include("warning", "info")
  end

  it "falls back to error for an unknown severity" do
    described_class.new.report(
      RuntimeError.new("odd"),
      handled: true,
      severity: :fatal,
      context: {}
    )
    PostDeploy.flush
    expect(PostDeploy::Testing.events.first[:level]).to eq("error")
  end
end
