# frozen_string_literal: true

require "test_helper"

# WEAK suite: it EXECUTES every method (so the lines are covered, not
# no_coverage) but asserts almost nothing — exactly the "coverage theater" a
# mutation run is meant to expose. Pointed at this suite, Mutineer should report
# surviving mutants and a sub-100% score, so a `--threshold` gate fails (exit 1).
class OrderWeakTest < ActiveSupport::TestCase
  def test_methods_return_plausible_shapes
    order = orders(:bulk)
    assert_kind_of Integer, order.subtotal_cents
    assert_kind_of Integer, order.total_cents
    assert_includes [true, false], order.free_shipping?
  end
end
