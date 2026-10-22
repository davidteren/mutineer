# frozen_string_literal: true

RSpec.describe "a group whose after(:all) raises" do
  after(:all) { raise "teardown failed" }

  it("fails") { expect(1).to eq(2) } if ENV["MUTINEER_FIXTURE_FAIL"]
  it("passes") { expect(1).to eq(1) }
end
