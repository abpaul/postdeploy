# frozen_string_literal: true

require "spec_helper"

RSpec.describe PostDeploy::Dedup do
  before { described_class.reset! }

  it "returns a fresh, non-duplicate result for a never-seen exception" do
    result = described_class.resolve(StandardError.new("boom"), "err_fresh")
    expect(result).to eq(id: "err_fresh", duplicate: false)
  end

  it "dedupes the SAME exception object captured twice within the window, returning the first id" do
    error = StandardError.new("boom")

    first = described_class.resolve(error, "err_first")
    second = described_class.resolve(error, "err_second")

    expect(first).to eq(id: "err_first", duplicate: false)
    expect(second).to eq(id: "err_first", duplicate: true)
  end

  it "never dedupes two DIFFERENT exception objects, even with the same class and message" do
    first = described_class.resolve(StandardError.new("boom"), "err_a")
    second = described_class.resolve(StandardError.new("boom"), "err_b")

    expect(first[:duplicate]).to be false
    expect(second[:duplicate]).to be false
  end

  it "dedupes the same primitive value (e.g. a raw String) captured twice" do
    first = described_class.resolve("just a string", "err_a")
    second = described_class.resolve("just a string", "err_a-dup")

    expect(first).to eq(id: "err_a", duplicate: false)
    expect(second).to eq(id: "err_a", duplicate: true)
  end

  it "never dedupes two different primitive values" do
    first = described_class.resolve("string one", "err_a")
    second = described_class.resolve("string two", "err_b")

    expect(first[:duplicate]).to be false
    expect(second[:duplicate]).to be false
  end

  it "reports the same error again once the window has expired" do
    error = StandardError.new("boom")
    allow(described_class).to receive(:monotonic_now).and_return(0.0, described_class::WINDOW_SECONDS + 1)

    first = described_class.resolve(error, "err_first")
    second = described_class.resolve(error, "err_second")

    expect(first[:duplicate]).to be false
    expect(second).to eq(id: "err_second", duplicate: false)
  end

  it "never raises even when the error object rejects the ivar write (frozen)" do
    error = StandardError.new("boom").freeze

    expect { described_class.resolve(error, "err_frozen") }.not_to raise_error
    expect(described_class.resolve(error, "err_frozen")[:duplicate]).to be false
  end

  it "guards the identity path too: two threads racing the SAME exception object never both see duplicate: false" do
    error = StandardError.new("boom")
    results = Queue.new
    ready = Queue.new
    go = Queue.new

    threads = Array.new(20) do |i|
      Thread.new do
        ready << true
        go.pop
        results << described_class.resolve(error, "err_#{i}")
      end
    end
    20.times { ready.pop }
    20.times { go << true }
    threads.each(&:join)

    outcomes = Array.new(20) { results.pop }
    expect(outcomes.count { |r| r[:duplicate] == false }).to eq(1)
  end
end
