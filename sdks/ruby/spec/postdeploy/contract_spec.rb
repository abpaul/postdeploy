# frozen_string_literal: true

require "spec_helper"
require "json"
require "digest"

# Top-level (unnamespaced) so `.class.name` renders the bare
# "ContractTestError" the golden fixture expects -- matching the Elixir
# SDK's own top-level `ContractTestError` (see
# sdks/elixir/test/post_deploy/contract_test.exs).
class ContractTestError < StandardError; end

RSpec.describe "golden envelope contract (issue #18)" do
  # Canonical input documented in sdks/contract/README.md. Frames are
  # already-built wire hashes, not a real exception's backtrace: this SDK's
  # public `exception_item` always derives frames from
  # `Exception#backtrace`(_locations), which is tied to THIS file's own
  # path/line -- never reproducible across three languages. `cap_frames`
  # and `base_item` are pure, public `module_function`s independent of
  # where the frames came from, so calling them directly with the literal
  # canonical frames exercises the same capping/shape code `exception_item`
  # itself uses, without requiring an unreproducible real stack trace.
  # The golden contract is owned by the product and lives in the same
  # repository at `sdks/contract`, which is the default. POSTDEPLOY_CONTRACT_DIR
  # overrides it to test this SDK against another checkout of the fixtures.
  # Either way the manifest version and per-item digests are verified below.
  contract_version = "2.0.0"
  expected_digests = {
    "exception_item.json" => "sha256:a970a83c0b7f8a1d74b8602afd886941634c711e600e41e2dc6ea579f868a380",
    "message_item.json" => "sha256:0f14c4f20605fed9a844646905047835033a7c6ade38fc1cb1d7da0158362e8f",
    "measure_event.json" => "sha256:132914d7468c8909baad2509bfb17de8ee30d585259c783a72d21f9446b6a483",
    "session_item.json" => "sha256:3bfe1d1458a03a3ced1b725c86d2a9aabbd57129f7aeb6a529d2d923ede8ec40"
  }.freeze


  let(:contract_dir) do
    dir = ENV["POSTDEPLOY_CONTRACT_DIR"]
    dir = File.expand_path("../../../contract", __dir__) if dir.nil? || dir.empty?
    unless File.directory?(dir)
      raise "contract fixtures not found at #{dir}. They live in this repository at " \
            "sdks/contract; set POSTDEPLOY_CONTRACT_DIR to use another checkout."
    end

    manifest = JSON.parse(File.read(File.join(dir, "manifest.json")))
    unless manifest["version"] == contract_version && manifest["items"] == expected_digests
      raise "contract version or independently pinned digest mismatch"
    end

    checksum_file = File.readlines(File.join(dir, "SHA256SUMS")).to_h do |line|
      digest, name = line.strip.split(/\s+/, 2)
      [name, "sha256:#{digest}"]
    end

    expected_digests.each do |name, expected|
      raise "contract SHA256SUMS mismatch for #{name}" unless checksum_file[name] == expected

      actual = "sha256:#{Digest::SHA256.hexdigest(File.binread(File.join(dir, name)))}"
      unless actual == expected
        raise "contract checksum mismatch for #{name}: expected #{expected}, got #{actual}"
      end
    end

    dir
  end
  let(:non_deterministic_keys) { %i[id timestamp] }

  let(:config) do
    PostDeploy::Configuration.new.tap do |c|
      c.key = "alp_p_contract_test"
      c.environment = "test"
      c.release = "1.0.0"
    end
  end

  let(:canonical_frames) do
    [
      { file: "app/worker.ex", function: "MyApp.Worker.perform/1", lineno: 42, colno: 5, in_app: true },
      { file: "lib/some_lib.ex", function: "SomeLib.call/2", lineno: 10, in_app: false }
    ]
  end

  let(:canonical_breadcrumbs) do
    [
      { category: "nav", message: "clicked checkout", level: "info", ts: "2024-01-01T00:00:00.000Z" },
      { category: "http", message: "POST /api/orders", level: "info", ts: "2024-01-01T00:00:01.000Z" }
    ]
  end

  def golden(contract_dir, name)
    JSON.parse(File.read(File.join(contract_dir, name)))
  end

  def normalize(item, non_deterministic_keys)
    json = JSON.parse(JSON.generate(item))
    json.reject { |key, _| non_deterministic_keys.map(&:to_s).include?(key) }
  end

  it "matches the golden exception item" do
    exception = ContractTestError.new("canonical contract test exception")

    item = PostDeploy::Envelope.exception_item(
      id: "err_ignored",
      exception: exception,
      config: config,
      level: "error",
      contexts: { extra: { cart_id: "cart_123", items: 3 } },
      tags: { team: "observability", flow: "checkout" },
      breadcrumbs: canonical_breadcrumbs,
      user: { id: "user_42", email: "person@example.com" },
      fingerprint: %w[checkout timeout],
      frames: canonical_frames
    )

    expect(normalize(item, non_deterministic_keys)).to eq(normalize(golden(contract_dir, "exception_item.json"), non_deterministic_keys))
  end

  it "matches the golden message item" do
    item = PostDeploy::Envelope.message_item(
      id: "err_ignored",
      message: "canonical contract test message",
      config: config,
      level: "warning",
      contexts: { extra: { note: "message-level context" } },
      tags: { team: "observability" },
      breadcrumbs: [{ category: "nav", message: "opened settings", level: "info", ts: "2024-01-01T00:00:00.000Z" }],
      user: { id: "user_42", email: "person@example.com" }
    )

    expect(normalize(item, non_deterministic_keys)).to eq(normalize(golden(contract_dir, "message_item.json"), non_deterministic_keys))
  end

  it "matches the golden session item" do
    session = PostDeploy::Session.new
    session.mark_crashed

    item = PostDeploy::Envelope.session_item(session: session, config: config)

    expect(normalize(item, non_deterministic_keys)).to eq(normalize(golden(contract_dir, "session_item.json"), non_deterministic_keys))
  end
end
