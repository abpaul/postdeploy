# frozen_string_literal: true

require "spec_helper"

RSpec.describe PostDeploy::Id do
  describe ".generate_event_id" do
    it "is err_-prefixed" do
      expect(described_class.generate_event_id).to start_with("err_")
    end

    it "is a valid UUIDv7: version nibble 7, variant bits 10" do
      id = described_class.generate_event_id.delete_prefix("err_")
      expect(id).to match(/\A[0-9a-f]{8}-[0-9a-f]{4}-7[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}\z/)
    end

    it "generates a unique id per call" do
      ids = Array.new(100) { described_class.generate_event_id }
      expect(ids.uniq.length).to eq(100)
    end

    it "is time-ordered: ids generated later sort after earlier ones" do
      first = described_class.generate_event_id
      sleep 0.002
      second = described_class.generate_event_id
      expect([first, second].sort).to eq([first, second])
    end
  end
end
