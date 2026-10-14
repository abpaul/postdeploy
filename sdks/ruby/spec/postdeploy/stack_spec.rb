# frozen_string_literal: true

require "spec_helper"
require_relative "../fixtures/source_context_sample"

RSpec.describe PostDeploy::Stack do
  def raise_in_app
    raise "boom"
  rescue StandardError => e
    e
  end

  describe ".frames_for" do
    it "maps the backtrace to frames with file/lineno/function" do
      exception = raise_in_app
      frames = described_class.frames_for(exception, app_dirs: [__dir__])

      expect(frames).not_to be_empty
      first = frames.first
      expect(first[:file]).to eq(__FILE__)
      expect(first[:lineno]).to be_a(Integer)
      expect(first[:function]).to be_a(String)
    end

    it "marks frames under app_dirs as in_app" do
      exception = raise_in_app
      frames = described_class.frames_for(exception, app_dirs: [__dir__])

      expect(frames.first[:in_app]).to be true
    end

    it "marks frames outside app_dirs as not in_app" do
      exception = raise_in_app
      frames = described_class.frames_for(exception, app_dirs: ["/somewhere/else"])

      expect(frames.first[:in_app]).to be false
    end

    it "marks gem/library paths as not in_app even with no app_dirs configured" do
      expect(described_class.in_app?("/usr/lib/ruby/gems/3.3.0/gems/rack-3.0.0/lib/rack/builder.rb", [])).to be false
    end

    it "treats every path as in_app when app_dirs is empty and the path isn't a library path" do
      expect(described_class.in_app?("/home/app/app/controllers/widgets_controller.rb", [])).to be true
    end

    it "returns an empty array for an exception with no backtrace" do
      expect(described_class.frames_for(StandardError.new("no trace"))).to eq([])
    end
  end

  describe ".frames_for source context (context_lines:)" do
    fixture_path = File.expand_path("../fixtures/source_context_sample.rb", __dir__)
    fixture_lines = File.readlines(fixture_path)

    def raise_from_fixture
      SourceContextSample.raise_here
    rescue RuntimeError => e
      e
    end

    it "attaches pre_context/context_line/post_context to an in_app frame from a real fixture file" do
      exception = raise_from_fixture
      frames = described_class.frames_for(exception, app_dirs: [File.dirname(fixture_path)], context_lines: 3)
      frame = frames.find { |f| f[:file] == fixture_path }

      expect(frame).not_to be_nil
      lineno = frame[:lineno]
      expect(frame[:context_line]).to eq(fixture_lines[lineno - 1].chomp)
      expect(frame[:pre_context]).to eq(fixture_lines[[lineno - 4, 0].max...(lineno - 1)].map(&:chomp))
      expect(frame[:post_context]).to eq(fixture_lines[lineno...(lineno + 3)].map(&:chomp))
    end

    it "does not attach source context to a library frame" do
      exception = raise_from_fixture
      frames = described_class.frames_for(exception, app_dirs: [File.dirname(fixture_path)], context_lines: 3)
      library_frame = frames.find { |f| f[:in_app] == false }

      expect(library_frame).not_to be_nil
      expect(library_frame).not_to have_key(:context_line)
      expect(library_frame).not_to have_key(:pre_context)
    end

    it "does not raise when the frame's source file is missing" do
      expect do
        described_class.build_frame("/nonexistent/path/does_not_exist.rb", 5, "whatever", [], 3)
      end.not_to raise_error

      frame = described_class.build_frame("/nonexistent/path/does_not_exist.rb", 5, "whatever", [], 3)
      expect(frame).not_to have_key(:context_line)
    end

    it "disables source-context capture when context_lines is 0" do
      exception = raise_from_fixture
      frames = described_class.frames_for(exception, app_dirs: [File.dirname(fixture_path)], context_lines: 0)
      frame = frames.find { |f| f[:file] == fixture_path }

      expect(frame).not_to be_nil
      expect(frame).not_to have_key(:context_line)
    end
  end
end
