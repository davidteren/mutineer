# frozen_string_literal: true

# MUTINEER_FIXTURE_FIRST sets the first example: fail, skip, pending or pass.
# The second example writes MUTINEER_FIXTURE_MARKER.
RSpec.describe "stop at first failure fixture", order: :defined do
  it "runs first" do
    case ENV.fetch("MUTINEER_FIXTURE_FIRST")
    when "fail" then expect(1).to eq(2)
    when "skip" then skip "the first example skips"
    when "pending"
      pending "the first example is pending"
      expect(1).to eq(2)
    else expect(1).to eq(1)
    end
  end

  it "writes the marker" do
    File.write(ENV.fetch("MUTINEER_FIXTURE_MARKER"), "ran")
  end
end
