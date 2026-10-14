# frozen_string_literal: true

require "spec_helper"
require "sidekiq"
require_relative "../../lib/postdeploy/sidekiq"

RSpec.describe PostDeploy::Sidekiq::ErrorHandler do
  before { PostDeploy.configure { |c| c.test_mode = true } }

  let(:handler) { described_class.new }
  let(:worker) { double("worker", class: double(name: "FallbackWorkerName")) }
  let(:job) { { "class" => "HardWorker", "queue" => "default", "jid" => "abc123", "args" => ["user_42", { "password" => "hunter2" }] } }

  it "captures the job exception with job context and re-raises so Sidekiq's retry still runs" do
    expect do
      handler.call(worker, job, "default") { raise RuntimeError, "job boom" }
    end.to raise_error(RuntimeError, "job boom")

    expect(PostDeploy.test_transport.envelopes.length).to eq(1)
    item = PostDeploy.test_transport.envelopes.first[:items].first
    expect(item[:exception][:type]).to eq("RuntimeError")
    expect(item[:mechanism]).to eq("sidekiq")
  end

  it "attaches job class, queue, jid to the captured event" do
    begin
      handler.call(worker, job, "default") { raise "job boom" }
    rescue RuntimeError
      nil
    end

    item = PostDeploy.test_transport.envelopes.first[:items].first
    job_ctx = item[:contexts][:job]
    expect(job_ctx[:class]).to eq("HardWorker")
    expect(job_ctx[:queue]).to eq("default")
    expect(job_ctx[:jid]).to eq("abc123")
  end

  it "scrubs sensitive job args before sending" do
    begin
      handler.call(worker, job, "default") { raise "job boom" }
    rescue RuntimeError
      nil
    end

    item = PostDeploy.test_transport.envelopes.first[:items].first
    args = item[:contexts][:job][:args]
    expect(args.last["password"]).to eq("[FILTERED]")
    expect(args.first).to eq("user_42")
  end

  it "does not capture anything when the job succeeds" do
    handler.call(worker, job, "default") { "ok" }

    expect(PostDeploy.test_transport.envelopes).to be_empty
  end

  it "falls back to the worker's class name when the job payload has no class" do
    classless_job = { "args" => [] }

    begin
      handler.call(worker, classless_job, "default") { raise "job boom" }
    rescue RuntimeError
      nil
    end

    item = PostDeploy.test_transport.envelopes.first[:items].first
    expect(item[:contexts][:job][:class]).to eq("FallbackWorkerName")
  end
end

RSpec.describe PostDeploy::Sidekiq do
  # `Sidekiq.configure_server` only fires its block immediately when
  # `Sidekiq.server?` is true (otherwise it's a genuine Sidekiq server
  # process boot detector, deferring registration) -- outside a real
  # `bundle exec sidekiq` process (i.e. in this spec run) that's false, so
  # it's stubbed here the same way a real server process would already
  # have set it by the time a host app's initializer calls `install!`.
  before { allow(::Sidekiq).to receive(:server?).and_return(true) }
  after { PostDeploy::Sidekiq.reset! }

  it "installs ErrorHandler onto Sidekiq's server middleware chain" do
    PostDeploy::Sidekiq.reset!
    PostDeploy::Sidekiq.install!

    chain = ::Sidekiq.default_configuration.server_middleware
    expect(chain.exists?(PostDeploy::Sidekiq::ErrorHandler)).to be true
  end

  it "is idempotent across repeated install! calls, never adding a duplicate middleware entry" do
    PostDeploy::Sidekiq.reset!
    3.times { PostDeploy::Sidekiq.install! }

    chain = ::Sidekiq.default_configuration.server_middleware
    count = chain.entries.count { |entry| entry.klass == PostDeploy::Sidekiq::ErrorHandler }
    expect(count).to eq(1)
  end
end
