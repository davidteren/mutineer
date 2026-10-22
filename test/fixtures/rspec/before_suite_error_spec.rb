# frozen_string_literal: true

RSpec.configure do |config|
  config.before(:suite) { raise "suite setup failed" }
end

RSpec.describe "a suite whose before(:suite) raises" do
  it("passes") { expect(1).to eq(1) }
end
