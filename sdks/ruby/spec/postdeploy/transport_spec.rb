# frozen_string_literal: true

require "spec_helper"

RSpec.describe PostDeploy::Transport do
  let(:config) do
    PostDeploy::Configuration.new.tap do |c|
      c.key = "alp_p_test_key"
      c.endpoint = "https://ingest.example.test"
      c.open_timeout = 1
      c.read_timeout = 1
    end
  end
  # A no-op sleeper: retry/backoff behavior is asserted on its own below by
  # inspecting what it was called with, never by actually waiting on real
  # wall-clock time.
  let(:sleeper_calls) { [] }
  let(:sleeper) { ->(seconds) { sleeper_calls << seconds } }
  let(:transport) { described_class.new(config, sleeper: sleeper) }
  let(:envelope) { { header: { key: config.key }, items: [{ id: "err_1" }] } }

  it "posts to POST /e/errors with a Bearer Authorization header and JSON content-type" do
    stub = stub_request(:post, "https://ingest.example.test/e/errors")
           .with(
             headers: { "Content-Type" => "application/json", "Authorization" => "Bearer alp_p_test_key" },
             body: JSON.generate(envelope)
           )
           .to_return(status: 202, body: "")

    expect(transport.send_envelope(envelope)).to eq(:sent)
    expect(stub).to have_been_requested
  end

  it "never raises on a 5xx response and reports :rejected (a non-network failure)" do
    stub_request(:post, "https://ingest.example.test/e/errors").to_return(status: 500)

    expect { transport.send_envelope(envelope) }.not_to raise_error
    expect(transport.send_envelope(envelope)).to eq(:rejected)
  end

  it "never raises and returns :error on a connection timeout" do
    stub_request(:post, "https://ingest.example.test/e/errors").to_timeout

    expect { transport.send_envelope(envelope) }.not_to raise_error
    expect(transport.send_envelope(envelope)).to eq(:error)
  end

  it "never raises and returns :error when the host is unreachable" do
    stub_request(:post, "https://ingest.example.test/e/errors").to_raise(SocketError.new("getaddrinfo failed"))

    expect { transport.send_envelope(envelope) }.not_to raise_error
    expect(transport.send_envelope(envelope)).to eq(:error)
  end

  it "never sends an envelope over the configured MAX_ENVELOPE_BYTES cap" do
    huge_envelope = { items: [{ id: "err_1", message: "x" * 2_000_000 }] }
    expect(transport.send_envelope(huge_envelope)).to eq(:oversized)
    expect(a_request(:post, "https://ingest.example.test/e/errors")).not_to have_been_made
  end

  describe "retry (issue #15)" do
    it "retries a transient 5xx and delivers the envelope on the next attempt" do
      stub = stub_request(:post, "https://ingest.example.test/e/errors")
             .to_return({ status: 503 }, { status: 202 })

      expect(transport.send_envelope(envelope)).to eq(:sent)
      expect(stub).to have_been_requested.times(2)
      expect(sleeper_calls.length).to eq(1)
    end

    it "gives up after 3 total attempts against a persistent 5xx" do
      stub = stub_request(:post, "https://ingest.example.test/e/errors").to_return(status: 500)

      expect(transport.send_envelope(envelope)).to eq(:rejected)
      expect(stub).to have_been_requested.times(3)
      expect(sleeper_calls.length).to eq(2)
    end

    it "does not retry a permanent 404 (unrecognized route)" do
      stub = stub_request(:post, "https://ingest.example.test/e/errors").to_return(status: 404)

      expect(transport.send_envelope(envelope)).to eq(:rejected)
      expect(stub).to have_been_requested.times(1)
      expect(sleeper_calls).to be_empty
    end

    it "does not retry a permanent 401 (bad key)" do
      stub_request(:post, "https://ingest.example.test/e/errors").to_return(status: 401)

      expect(transport.send_envelope(envelope)).to eq(:rejected)
      expect(sleeper_calls).to be_empty
    end

    it "honors a 429's Retry-After instead of the default backoff, delivering on retry" do
      stub = stub_request(:post, "https://ingest.example.test/e/errors")
             .to_return({ status: 429, headers: { "Retry-After" => "7" } }, { status: 202 })

      expect(transport.send_envelope(envelope)).to eq(:sent)
      expect(stub).to have_been_requested.times(2)
      expect(sleeper_calls).to eq([7.0])
    end

    it "caps an oversized Retry-After at 30 seconds" do
      stub_request(:post, "https://ingest.example.test/e/errors")
        .to_return({ status: 429, headers: { "Retry-After" => "9999" } }, { status: 202 })

      transport.send_envelope(envelope)

      expect(sleeper_calls).to eq([30.0])
    end
  end
end
