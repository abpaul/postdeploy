# frozen_string_literal: true

require "spec_helper"

RSpec.describe PostDeploy::Envelope do
  let(:config) do
    PostDeploy::Configuration.new.tap do |c|
      c.key = "alp_p_test_key"
      c.environment = "staging"
      c.release = "v9.9.9"
      c.app_dirs = [__dir__]
    end
  end

  # Golden test: this exact shape must stay wire-compatible with the JS SDK
  # (packages/sdk/src/core/observe/{client,envelope}.ts) and the Elixir SDK
  # (issue #13) — the server's POST /e/errors envelope validation is the
  # single accepted shape all three SDKs target (docs/BUILD.md §5).
  it "builds the documented POST /e/errors envelope for a captured exception" do
    exception = begin
      raise ArgumentError, "bad thing happened"
    rescue StandardError => e
      e
    end

    item = described_class.exception_item(id: "err_01930000-0000-7000-8000-000000000000", exception: exception, config: config)
    envelope = described_class.wrap(config: config, item: item)

    expect(envelope).to match(
      header: {
        key: "alp_p_test_key",
        sdk: { name: "postdeploy", version: PostDeploy::VERSION, platform: "ruby" },
        sent_at: match(/\A\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}Z\z/)
      },
      items: [
        {
          id: "err_01930000-0000-7000-8000-000000000000",
          type: "exception",
          timestamp: match(/\A\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}Z\z/),
          level: "error",
          release: "v9.9.9",
          environment: "staging",
          mechanism: "generic",
          exception: {
            type: "ArgumentError",
            value: "bad thing happened",
            stacktrace: {
              frames: array_including(
                include(file: __FILE__, function: a_kind_of(String), lineno: a_kind_of(Integer), in_app: true)
              )
            }
          }
        }
      ]
    )
  end

  it "is JSON-serializable to the exact wire shape (round-trips through JSON with string keys)" do
    exception = begin
      raise "boom"
    rescue StandardError => e
      e
    end

    item = described_class.exception_item(id: "err_test", exception: exception, config: config)
    envelope = described_class.wrap(config: config, item: item)
    parsed = JSON.parse(JSON.generate(envelope))

    expect(parsed.dig("header", "key")).to eq("alp_p_test_key")
    expect(parsed.dig("items", 0, "id")).to eq("err_test")
    expect(parsed.dig("items", 0, "exception", "type")).to eq("RuntimeError")
  end

  it "builds a message item without an exception key" do
    item = described_class.message_item(id: "err_msg", message: "hello", config: config, level: "info")
    expect(item).to match(
      id: "err_msg",
      type: "message",
      timestamp: an_instance_of(String),
      level: "info",
      release: "v9.9.9",
      environment: "staging",
      mechanism: "generic",
      message: "hello"
    )
    expect(item).not_to have_key(:exception)
  end

  it "omits stacktrace entirely when the exception has no backtrace" do
    item = described_class.exception_item(id: "err_no_bt", exception: StandardError.new("no trace"), config: config)
    expect(item[:exception]).not_to have_key(:stacktrace)
  end

  it "includes tags and context only when present, never as empty objects" do
    item = described_class.message_item(id: "err_x", message: "m", config: config)
    expect(item).not_to have_key(:tags)
    expect(item).not_to have_key(:contexts)

    tagged = described_class.message_item(id: "err_y", message: "m", config: config, tags: { "region" => "eu" }, context: { "order_id" => 42 })
    expect(tagged[:tags]).to eq({ "region" => "eu" })
    expect(tagged[:contexts]).to eq(extra: { "order_id" => 42 })
  end

  describe "context vs contexts (issue #17)" do
    it "accepts a named contexts: map alongside the context: convenience" do
      item = described_class.message_item(
        id: "err_ctx", message: "m", config: config,
        context: { order_id: 42 },
        contexts: { runtime: { ruby: RUBY_VERSION } }
      )

      expect(item[:contexts]).to eq(extra: { order_id: 42 }, runtime: { ruby: RUBY_VERSION })
    end

    it "accepts contexts: alone, without a context: convenience key" do
      item = described_class.message_item(id: "err_ctx2", message: "m", config: config, contexts: { request: { path: "/x" } })
      expect(item[:contexts]).to eq(request: { path: "/x" })
    end
  end

  describe "fingerprint (issue #17)" do
    it "puts the fingerprint array on the wire when given" do
      item = described_class.message_item(id: "err_fp", message: "m", config: config, fingerprint: %w[custom-group])
      expect(item[:fingerprint]).to eq(%w[custom-group])
    end

    it "is omitted entirely when not given" do
      item = described_class.message_item(id: "err_no_fp", message: "m", config: config)
      expect(item).not_to have_key(:fingerprint)
    end

    it "caps entries at MAX_FINGERPRINT_ENTRIES, keeping the first ones" do
      fingerprint = Array.new(30) { |i| "part-#{i}" }
      item = described_class.message_item(id: "err_fp_many", message: "m", config: config, fingerprint: fingerprint)
      expect(item[:fingerprint].length).to eq(described_class::MAX_FINGERPRINT_ENTRIES)
      expect(item[:fingerprint].first).to eq("part-0")
    end

    it "caps an individual fingerprint entry's length" do
      item = described_class.message_item(id: "err_fp_long", message: "m", config: config, fingerprint: ["x" * 500])
      expect(item[:fingerprint].first.length).to eq(described_class::MAX_FINGERPRINT_CHARS)
    end
  end

  describe "user" do
    it "puts the correct user object on the wire for a captured exception" do
      exception = begin
        raise "boom"
      rescue StandardError => e
        e
      end

      item = described_class.exception_item(id: "err_user", exception: exception, config: config, user: { id: "user_42", email: "dev@example.com" })

      expect(item[:user]).to eq(id: "user_42", email: "dev@example.com")
    end

    it "puts the correct user object on the wire for a captured message" do
      item = described_class.message_item(id: "err_user_msg", message: "m", config: config, user: { id: "user_1" })
      expect(item[:user]).to eq(id: "user_1")
    end

    it "accepts string keys" do
      item = described_class.message_item(id: "err_user_str", message: "m", config: config, user: { "id" => "user_9", "email" => "x@example.com" })
      expect(item[:user]).to eq(id: "user_9", email: "x@example.com")
    end

    it "is omitted entirely when no user is given" do
      item = described_class.message_item(id: "err_no_user", message: "m", config: config)
      expect(item).not_to have_key(:user)
    end

    it "drops unrecognized keys — the server's user schema is .strict() with only id/email" do
      item = described_class.message_item(id: "err_user_strict", message: "m", config: config, user: { id: "user_1", username: "shouldbedropped", ip_address: "1.2.3.4" })
      expect(item[:user]).to eq(id: "user_1")
    end

    it "caps an oversized id/email rather than sending them unbounded" do
      huge = "x" * 10_000
      item = described_class.message_item(id: "err_user_cap", message: "m", config: config, user: { id: huge, email: huge })
      expect(item[:user][:id].length).to eq(described_class::MAX_USER_FIELD_CHARS)
      expect(item[:user][:email].length).to eq(described_class::MAX_USER_FIELD_CHARS)
    end

    it "is omitted when given an empty hash" do
      item = described_class.message_item(id: "err_user_empty", message: "m", config: config, user: {})
      expect(item).not_to have_key(:user)
    end
  end

  describe "per-field caps (an oversized field is trimmed, the event still sends)" do
    it "drops trailing stack frames rather than the whole event" do
      huge_message = "x" * 500
      # Build far more frames than MAX_STACK_TRACE_CHARS can hold.
      frames = Array.new(200) { { file: __FILE__, function: huge_message, lineno: 1, in_app: true } }

      capped = described_class.cap_frames(frames, described_class::MAX_STACK_TRACE_CHARS)

      expect(capped.length).to be < frames.length
      expect(JSON.generate(capped).bytesize).to be <= described_class::MAX_STACK_TRACE_CHARS
      expect(capped).not_to be_empty
    end

    it "replaces an oversized context with a truncation marker instead of a partial/unparseable string" do
      huge_context = { extra: { blob: "x" * 20_000 } }

      capped = described_class.cap_context(huge_context, described_class::MAX_CONTEXT_CHARS)

      expect(capped).to eq(_truncated: true, _original_chars: JSON.generate(huge_context).bytesize)
    end

    it "leaves a context under budget untouched" do
      small_context = { extra: { order_id: 42 } }
      expect(described_class.cap_context(small_context, described_class::MAX_CONTEXT_CHARS)).to eq(small_context)
    end

    it "drops an oversized tags object entirely rather than send a truncated Hash" do
      huge_tags = { "blob" => "x" * 10_000 }
      expect(described_class.cap_tags(huge_tags, described_class::MAX_TAGS_CHARS)).to be_nil
    end

    it "keeps a tags object under budget" do
      tags = { "region" => "eu" }
      expect(described_class.cap_tags(tags, described_class::MAX_TAGS_CHARS)).to eq(tags)
    end

    it "caps breadcrumbs to the server ceiling, keeping the most recent" do
      breadcrumbs = Array.new(150) { |i| { category: "nav", message: "step #{i}" } }

      capped = described_class.cap_breadcrumbs(breadcrumbs, described_class::SERVER_MAX_BREADCRUMBS)

      expect(capped.length).to eq(described_class::SERVER_MAX_BREADCRUMBS)
      expect(capped.last[:message]).to eq("step 149")
    end

    it "caps an individual breadcrumb's message and category length" do
      breadcrumbs = [{ category: "x" * 500, message: "y" * 5_000 }]

      capped = described_class.cap_breadcrumbs(breadcrumbs, described_class::SERVER_MAX_BREADCRUMBS)

      expect(capped.first[:category].length).to eq(described_class::MAX_BREADCRUMB_CATEGORY_CHARS)
      expect(capped.first[:message].length).to eq(described_class::MAX_BREADCRUMB_MESSAGE_CHARS)
    end

    it "builds a full exception_item where an oversized stacktrace is trimmed, not dropped" do
      exception = begin
        raise "boom"
      rescue StandardError => e
        e
      end
      # Force frames far past the cap by stubbing Stack.frames_for.
      giant_frames = Array.new(200) { { file: __FILE__, function: "x" * 100, lineno: 1, in_app: true } }
      allow(PostDeploy::Stack).to receive(:frames_for).and_return(giant_frames)

      item = described_class.exception_item(id: "err_cap", exception: exception, config: config)

      expect(item[:exception]).to have_key(:stacktrace)
      expect(item[:exception][:stacktrace][:frames].length).to be < giant_frames.length
      expect(item[:exception][:stacktrace][:frames]).not_to be_empty
    end
  end

  describe "cause chain" do
    let(:config) { PostDeploy::Configuration.new }

    def raise_wrapped
      begin
        begin
          raise ArgumentError, "root cause"
        rescue StandardError
          raise TypeError, "middle wrapper"
        end
      rescue StandardError
        raise "outer wrapper"
      end
    rescue StandardError => e
      e
    end

    it "walks Exception#cause into the wire cause chain with frames" do
      item = described_class.exception_item(id: "err_cause", exception: raise_wrapped, config: config)

      outer = item[:exception]
      expect(outer[:type]).to eq("RuntimeError")

      middle = outer[:cause]
      expect(middle[:type]).to eq("TypeError")
      expect(middle[:value]).to eq("middle wrapper")
      expect(middle[:stacktrace][:frames]).not_to be_empty

      root = middle[:cause]
      expect(root[:type]).to eq("ArgumentError")
      expect(root[:value]).to eq("root cause")
      expect(root[:cause]).to be_nil
    end

    it "bounds the chain at MAX_CAUSE_DEPTH causes" do
      exception = nil
      7.times do |n|
        exception = begin
          begin
            raise "layer #{n}"
          rescue StandardError
            raise RuntimeError, "wrap #{n}", cause: exception
          end
        rescue StandardError => e
          e
        end
      end

      item = described_class.exception_item(id: "err_deep", exception: exception, config: config)

      depth = 0
      cursor = item[:exception][:cause]
      while cursor
        depth += 1
        cursor = cursor[:cause]
      end

      expect(depth).to eq(described_class::MAX_CAUSE_DEPTH)
    end

    it "omits the cause key for a cause-less exception" do
      exception = begin
        raise "solo"
      rescue StandardError => e
        e
      end

      item = described_class.exception_item(id: "err_solo", exception: exception, config: config)
      expect(item[:exception]).not_to have_key(:cause)
    end
  end
end
