# frozen_string_literal: true

require_relative "calculator"

# Strong suite: inputs chosen so every arithmetic mutation changes the result
# and is caught -> all mutants killed.
RSpec.describe RSpecCalculator do
  it "adds" do
    expect(subject.add(2, 3)).to eq(5)      # +->-: 2-3=-1 (killed)
  end

  it "multiplies" do
    expect(subject.multiply(3, 4)).to eq(12) # *->/: 3/4=0 (killed)
  end
end
