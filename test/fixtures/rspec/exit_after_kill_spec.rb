# frozen_string_literal: true

# The first example fails; then MUTINEER_FIXTURE_MODE picks how the run ends:
# in a later example, in the failing group's after(:all), in a later group, or
# in after(:suite). A --matrix run must give the verdict a run without it
# gives (#191).
RSpec.configure do |config|
  config.after(:suite) { exit 0 if ENV.fetch("MUTINEER_FIXTURE_MODE", nil) == "suite_exit" }
end

RSpec.describe "exit after kill" do
  after(:all) do
    exit 0 if ENV.fetch("MUTINEER_FIXTURE_MODE", nil) == "after_all_exit"
    exit!(0) if ENV.fetch("MUTINEER_FIXTURE_MODE", nil) == "after_all_exit_bang"
  end

  it("fails first") { expect(1).to eq(2) }

  it "runs later" do
    exit 0 if ENV.fetch("MUTINEER_FIXTURE_MODE", nil) == "later_exit"
    exit 2 if ENV.fetch("MUTINEER_FIXTURE_MODE", nil) == "later_exit_two"
  end
end

RSpec.describe "a later group" do
  before(:all) { exit 0 if ENV.fetch("MUTINEER_FIXTURE_MODE", nil) == "later_group_exit" }

  it("passes") { expect(1).to eq(1) }
end
