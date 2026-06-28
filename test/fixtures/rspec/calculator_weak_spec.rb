# frozen_string_literal: true

require_relative "calculator"

# Weak suite: add uses a 0 operand, so `+`<->`-` yield the same value and the
# add mutant survives undetected. multiply uses inputs that distinguish `*`/`/`,
# so that mutant is killed.
RSpec.describe RSpecCalculator do
  it "adds" do
    expect(subject.add(5, 0)).to eq(5)       # +->-: 5-0=5 (survives)
  end

  it "multiplies" do
    expect(subject.multiply(2, 3)).to eq(6)  # *->/: 2/3=0 (killed)
  end
end
