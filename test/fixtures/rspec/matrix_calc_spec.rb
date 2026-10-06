# frozen_string_literal: true

require_relative "matrix_calc"

RSpec.shared_examples "a matrix adder" do
  it "adds via shared" do
    expect(MatrixCalc.new.add(2, 3)).to eq(5)
  end
end

# Two examples share the description "checks", and the shared group is
# included twice: each is a test of its own, told apart by its example id.
RSpec.describe MatrixCalc do
  it "adds first" do
    expect(subject.add(2, 3)).to eq(5)
  end

  it "multiplies" do
    expect(subject.mul(2, 3)).to eq(6)
  end

  it "adds again" do
    expect(subject.add(4, 1)).to eq(5)
  end

  context "dup" do
    it "checks" do
      expect(subject.pos?(1)).to be(true) # passes under `>=`: blind
    end

    it "checks" do
      expect(subject.pos?(0)).to be(false) # fails under `>=`: the only killer
    end
  end

  it_behaves_like "a matrix adder"
  it_behaves_like "a matrix adder"

  it "is pending and fails" do
    pending("wip")
    expect(subject.add(1, 1)).to eq(3)
  end

  it "aggregates" do
    aggregate_failures do
      expect(subject.add(1, 1)).to eq(2)
      expect(subject.mul(1, 1)).to eq(1)
    end
  end
end
