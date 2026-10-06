# frozen_string_literal: true

# Defined apart from the spec that includes it, with parameters.
RSpec.shared_examples "matrix adds" do |a, b, sum|
  it "adds correctly" do
    expect(MatrixCalc.new.add(a, b)).to eq(sum)
  end
end
