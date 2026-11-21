# frozen_string_literal: true

require "test_helper"

class InclusionValueTest < ActiveSupport::TestCase
  def test_switch
    assert InclusionValue.new(type: "switch", value: 1).switch?
    refute InclusionValue.new(type: "toggle", value: 1).switch?
  end
end
