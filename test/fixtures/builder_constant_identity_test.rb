# frozen_string_literal: true

require "minitest/autorun"
require_relative "builder_constant_holders"

# A new BuilderPoint object would fail the last line for every mutant.
class BuilderConstantIdentityTest < Minitest::Test
  def test_weak_runs_and_the_instance_keeps_its_class
    BuilderPoint.new(9).weak?
    assert_kind_of BuilderPoint, BUILDER_ORIGIN
  end
end
