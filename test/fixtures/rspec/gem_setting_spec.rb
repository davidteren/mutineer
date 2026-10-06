# frozen_string_literal: true

# Sets a setting that a gem added before the run, as a support file sets
# rspec-retry's verbose_retry.
RSpec.configure { |c| c.mutineer_gem_setting = true }

RSpec.describe "a setting that a gem added" do
  it "is set" do
    expect(RSpec.configuration.mutineer_gem_setting).to be(true)
  end
end
