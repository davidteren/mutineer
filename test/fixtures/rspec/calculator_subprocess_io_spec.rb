# frozen_string_literal: true

require_relative "calculator"

# The weak spec, with each expectation inside `to_stdout_from_any_process`.
# That matcher calls `$stdout.reopen(tempfile)`, so it needs `$stdout` to be a
# real IO. Same verdicts as calculator_weak_spec.rb -> exactly 1 survivor.
RSpec.describe RSpecCalculator do
  it "adds" do
    expect { expect(subject.add(5, 0)).to eq(5) }.to output("").to_stdout_from_any_process      # survives
  end

  it "multiplies" do
    expect { expect(subject.multiply(2, 3)).to eq(6) }.to output("").to_stdout_from_any_process # killed
  end
end
