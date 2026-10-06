# frozen_string_literal: true

require_relative "matrix_calc"
require_relative "matrix_shared"

# The two inclusions share a full description; only the second can kill `+`.
RSpec.describe MatrixCalc do
  it_behaves_like "matrix adds", 0, 0, 0 # blind: 0 + 0 == 0 - 0
  it_behaves_like "matrix adds", 2, 3, 5 # kills `+` -> `-`

  it "multiplies" do
    expect(subject.mul(2, 3)).to eq(6)
  end

  context "with a before(:context) that raises under a mutant" do
    before(:context) { raise "boom" if MatrixCalc.new.mul(2, 2) != 4 }

    it "inner one" do
      expect(1).to eq(1)
    end
  end
end
