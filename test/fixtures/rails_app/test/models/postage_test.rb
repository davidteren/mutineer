# frozen_string_literal: true

require "test_helper"

# Weak on purpose for `heavy?`: it calls it without checking the answer, so
# those mutants survive under redefine. `require_weight` mutants die on the
# last check. If a reload of postage.rb gave the subclasses the parent's
# callback back (#414), the saves would fail and every mutant would die.
class PostageTest < ActiveSupport::TestCase
  test "each subclass keeps its own skip of the parent callback" do
    FreePostage.new(weight_grams: 0).heavy?

    assert FreePostage.new(weight_grams: 0).save
    assert ExpressPostage.new(weight_grams: 0, express: true).save
    refute ExpressPostage.new(weight_grams: 0).save
  end
end
