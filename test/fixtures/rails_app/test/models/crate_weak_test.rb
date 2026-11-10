# frozen_string_literal: true

require "test_helper"

class CrateWeakTest < ActiveSupport::TestCase
  def test_saves_a_valid_crate
    crate = Crate.create!(label: "box")
    assert crate.persisted?
  end
end
