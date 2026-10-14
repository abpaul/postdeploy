# frozen_string_literal: true

require "spec_helper"

RSpec.describe PostDeploy::Session do
  after { Thread.current[:postdeploy_session] = nil }

  describe ".current" do
    it "is nil until a session is started" do
      expect(described_class.current).to be_nil
    end
  end

  describe ".with_clean_session" do
    it "starts a fresh healthy session with a ses_-prefixed opaque id" do
      described_class.with_clean_session do
        session = described_class.current
        expect(session.status).to eq(:healthy)
        expect(session.id).to start_with("ses_")
      end
    end

    it "restores the previous session (even nil) after the block, even if it raises" do
      described_class.with_clean_session { described_class.current.mark_errored }
      outer_session = described_class.current

      expect { described_class.with_clean_session { raise "boom" } }.to raise_error("boom")

      expect(described_class.current).to equal(outer_session)
    end
  end

  describe "#mark_errored" do
    it "upgrades a healthy session to errored" do
      session = described_class.new
      session.mark_errored
      expect(session.status).to eq(:errored)
    end

    it "never downgrades a crashed session" do
      session = described_class.new
      session.mark_crashed
      session.mark_errored
      expect(session.status).to eq(:crashed)
    end
  end

  describe "#mark_crashed" do
    it "upgrades a healthy or errored session to crashed" do
      session = described_class.new
      session.mark_crashed
      expect(session.status).to eq(:crashed)
    end
  end
end
