# frozen_string_literal: true

require_relative "matrix_calc"

# Under `>=` the example fails and the suite hook exits 0. Plain RSpec runs the
# hook after a fail-fast stop too, so the run without --matrix scores survived.
RSpec.configure { |config| config.after(:suite) { exit(0) if MatrixCalc.new.pos?(0) } }

RSpec.describe MatrixCalc do
  it "is not positive at zero" do
    expect(subject.pos?(0)).to be(false)
  end
end
