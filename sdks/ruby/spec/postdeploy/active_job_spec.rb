# frozen_string_literal: true

require "spec_helper"
require "active_job"
require "logger"
require_relative "../../lib/postdeploy/active_job"

ActiveJob::Base.queue_adapter = :inline
ActiveJob::Base.logger = Logger.new(IO::NULL)

RSpec.describe PostDeploy::ActiveJob do
  before do
    PostDeploy.configure { |c| c.test_mode = true }
    PostDeploy::ActiveJob.reset!
    PostDeploy::ActiveJob.install!
  end

  after { PostDeploy::ActiveJob.reset! }

  let(:raising_job_class) do
    Class.new(ActiveJob::Base) do
      self.queue_adapter = :inline
      queue_as :critical

      def self.name
        "ActiveJobSpecRaisingJob"
      end

      def perform(user_id, password:)
        raise "job boom for #{user_id}"
      end
    end
  end

  let(:ok_job_class) do
    Class.new(ActiveJob::Base) do
      self.queue_adapter = :inline

      def self.name
        "ActiveJobSpecOkJob"
      end

      def perform(*)
        "ok"
      end
    end
  end

  it "captures a raising job's exception and still lets the error propagate" do
    expect do
      raising_job_class.perform_now("user_42", password: "hunter2")
    end.to raise_error(RuntimeError, /job boom for user_42/)

    expect(PostDeploy.test_transport.envelopes.length).to eq(1)
    item = PostDeploy.test_transport.envelopes.first[:items].first
    expect(item[:exception][:type]).to eq("RuntimeError")
    expect(item[:mechanism]).to eq("active_job")
  end

  it "attaches job class and queue context" do
    begin
      raising_job_class.perform_now("user_42", password: "hunter2")
    rescue RuntimeError
      nil
    end

    item = PostDeploy.test_transport.envelopes.first[:items].first
    job_ctx = item[:contexts][:job]
    expect(job_ctx[:class]).to eq("ActiveJobSpecRaisingJob")
    expect(job_ctx[:queue]).to eq("critical")
  end

  it "scrubs sensitive arguments before sending" do
    begin
      raising_job_class.perform_now("user_42", password: "hunter2")
    rescue RuntimeError
      nil
    end

    item = PostDeploy.test_transport.envelopes.first[:items].first
    arguments = item[:contexts][:job][:arguments]
    expect(JSON.generate(arguments)).not_to include("hunter2")
  end

  it "does not capture anything for a job that succeeds" do
    ok_job_class.perform_now("fine")

    expect(PostDeploy.test_transport.envelopes).to be_empty
  end
end
