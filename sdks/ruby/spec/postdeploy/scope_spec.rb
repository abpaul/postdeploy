# frozen_string_literal: true

require "spec_helper"

RSpec.describe PostDeploy::Scope do
  after { Thread.current[:postdeploy_scope] = nil }

  describe ".current" do
    it "is lazily created and stable within the same thread" do
      expect(described_class.current).to be(described_class.current)
    end
  end

  describe "#set_user / #set_tag / #set_context / #add_breadcrumb" do
    it "accumulates values on the current scope" do
      scope = described_class.current
      scope.set_user(id: "user_1")
      scope.set_tag("region", "eu")
      scope.set_context("request", { path: "/x" })
      scope.add_breadcrumb(message: "step 1", category: "nav")

      snapshot = scope.snapshot
      expect(snapshot[:user]).to eq(id: "user_1")
      expect(snapshot[:tags]).to eq("region" => "eu")
      expect(snapshot[:contexts]).to eq("request" => { path: "/x" })
      expect(snapshot[:breadcrumbs].length).to eq(1)
      expect(snapshot[:breadcrumbs].first[:message]).to eq("step 1")
    end

    it "defaults a breadcrumb's ts to now when not given" do
      described_class.current.add_breadcrumb(message: "x")
      expect(described_class.current.snapshot[:breadcrumbs].first[:ts]).to match(/\A\d{4}-\d{2}-\d{2}T/)
    end

    it "caps the breadcrumb ring buffer at MAX_BREADCRUMBS, keeping the most recent" do
      scope = described_class.current
      120.times { |i| scope.add_breadcrumb(message: "step #{i}") }

      breadcrumbs = scope.snapshot[:breadcrumbs]
      expect(breadcrumbs.length).to eq(described_class::MAX_BREADCRUMBS)
      expect(breadcrumbs.last[:message]).to eq("step 119")
      expect(breadcrumbs.first[:message]).to eq("step 20")
    end
  end

  describe ".with_clean_scope" do
    it "gives the block a fresh, empty scope and restores the previous one after" do
      described_class.current.set_user(id: "outer")

      described_class.with_clean_scope do
        expect(described_class.current.snapshot[:user]).to be_nil
        described_class.current.set_user(id: "inner")
      end

      expect(described_class.current.snapshot[:user]).to eq(id: "outer")
    end

    it "restores the previous scope even when the block raises" do
      described_class.current.set_user(id: "outer")

      expect do
        described_class.with_clean_scope { raise "boom" }
      end.to raise_error("boom")

      expect(described_class.current.snapshot[:user]).to eq(id: "outer")
    end
  end
end

RSpec.describe PostDeploy::ScopeMerge do
  it "lets an explicit user: override the ambient one" do
    merged = described_class.merge(ambient: { user: { id: "ambient" }, tags: {}, contexts: {}, breadcrumbs: [] }, user: { id: "explicit" }, tags: nil, contexts: nil, breadcrumbs: nil)
    expect(merged[:user]).to eq(id: "explicit")
  end

  it "falls back to the ambient user when user: is PostDeploy::UNSET (not given by the caller)" do
    merged = described_class.merge(ambient: { user: { id: "ambient" }, tags: {}, contexts: {}, breadcrumbs: [] }, user: PostDeploy::UNSET, tags: nil, contexts: nil, breadcrumbs: nil)
    expect(merged[:user]).to eq(id: "ambient")
  end

  it "an explicit user: nil clears the ambient user for this one capture, rather than falling back to it (issue #17 defect)" do
    merged = described_class.merge(ambient: { user: { id: "ambient" }, tags: {}, contexts: {}, breadcrumbs: [] }, user: nil, tags: nil, contexts: nil, breadcrumbs: nil)
    expect(merged[:user]).to be_nil
  end

  it "shallow-merges tags and contexts, with the explicit override winning key collisions" do
    ambient = { user: nil, tags: { "region" => "eu", "shared" => "ambient" }, contexts: { "request" => { a: 1 } }, breadcrumbs: [] }
    merged = described_class.merge(ambient: ambient, user: PostDeploy::UNSET, tags: { "shared" => "explicit", "plan" => "pro" }, contexts: { "request" => { b: 2 } }, breadcrumbs: nil)

    expect(merged[:tags]).to eq("region" => "eu", "shared" => "explicit", "plan" => "pro")
    expect(merged[:contexts]).to eq("request" => { b: 2 })
  end

  it "concatenates breadcrumbs, ambient trail first" do
    ambient = { user: nil, tags: {}, contexts: {}, breadcrumbs: [{ message: "ambient-1" }] }
    merged = described_class.merge(ambient: ambient, user: PostDeploy::UNSET, tags: nil, contexts: nil, breadcrumbs: [{ message: "explicit-1" }])

    expect(merged[:breadcrumbs]).to eq([{ message: "ambient-1" }, { message: "explicit-1" }])
  end
end
