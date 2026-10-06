# frozen_string_literal: true

require_relative "matrix_calc"

# The first example has no description of its own: RSpec words it from the
# matcher, so the name carries the value MatrixCalc#add returns, which a mutant
# changes. The example id stays the same.
RSpec.describe MatrixCalc do
  it { expect(1).to eq(subject.add(0, 1)) }

  it "multiplies" do
    expect(subject.mul(2, 3)).to eq(6)
  end
end
