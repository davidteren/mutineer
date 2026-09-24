# frozen_string_literal: true

require_relative "calculator"

# The weak spec, with a top-level `puts` that runs when the file loads, before
# any example runs. Same verdicts as calculator_weak_spec.rb -> exactly 1
# survivor.
puts "hello from load time"

RSpec.describe RSpecCalculator do
  it "adds" do
    expect(subject.add(5, 0)).to eq(5)       # survives
  end

  it "multiplies" do
    expect(subject.multiply(2, 3)).to eq(6)  # killed
  end
end
