# frozen_string_literal: true

# Fixture file for Stack source-context specs (spec/postdeploy/stack_spec.rb).
# Line numbers below are load-bearing: the spec asserts on specific source
# lines by number, so do not reformat this file.
module SourceContextSample
  def self.above_the_raise
    "line six"
  end

  def self.raise_here
    raise "boom on line ten"
  end

  def self.below_the_raise
    "line fourteen"
  end
end
