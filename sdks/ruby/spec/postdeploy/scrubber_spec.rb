# frozen_string_literal: true

require "spec_helper"

RSpec.describe PostDeploy::Scrubber do
  it "redacts a matching key in a nested hash" do
    item = { context: { password: "secret", ok: "yes" } }
    out = described_class.scrub(item, %w[password])
    expect(out[:context][:password]).to eq("[FILTERED]")
    expect(out[:context][:ok]).to eq("yes")
  end

  it "redacts values inside arrays" do
    item = { tags: [{ token: "abc" }, { name: "keep" }] }
    out = described_class.scrub(item, %w[token])
    expect(out[:tags][0][:token]).to eq("[FILTERED]")
    expect(out[:tags][1][:name]).to eq("keep")
  end

  it "matches keys case-insensitively" do
    item = { user: { "API_KEY" => "live" } }
    out = described_class.scrub(item, %w[api_key])
    expect(out[:user]["API_KEY"]).to eq("[FILTERED]")
  end

  it "returns the item unchanged when fields are empty" do
    item = { context: { password: "secret" } }
    expect(described_class.scrub(item, [])).to eq(item)
  end

  it "does not mutate the original item" do
    item = { context: { password: "secret" } }
    described_class.scrub(item, %w[password])
    expect(item[:context][:password]).to eq("secret")
  end
end
