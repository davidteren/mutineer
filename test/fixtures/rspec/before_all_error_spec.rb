# frozen_string_literal: true

# A group's before(:all) raises, so RSpec fails every example in it, nested
# groups included, from inside its own `rescue`. Then after(:suite) exits 0,
# which a run without --matrix reaches too (#191).
RSpec.configure do |config|
  config.after(:suite) { exit 0 }
end

RSpec.describe "a failing before(:all)" do
  before(:all) { raise "setup failed" }

  it("fails") { expect(1).to eq(1) }

  context "a nested group" do
    it("fails too") { expect(1).to eq(1) }
  end
end
