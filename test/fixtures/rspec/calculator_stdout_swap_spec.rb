# frozen_string_literal: true

require "stringio"
require_relative "calculator"

# The weak spec, with `$stdout` and `$stderr` left as StringIOs: once at load
# time and once inside an example that never restores them. Same verdicts as
# calculator_weak_spec.rb -> exactly 1 survivor.
$stdout = StringIO.new

RSpec.describe RSpecCalculator do
  it "adds" do
    $stdout = StringIO.new
    $stderr = StringIO.new
    expect(subject.add(5, 0)).to eq(5)       # survives
  end

  it "multiplies" do
    expect(subject.multiply(2, 3)).to eq(6)  # killed
  end
end
