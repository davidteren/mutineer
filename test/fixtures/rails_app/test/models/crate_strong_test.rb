# frozen_string_literal: true

require "test_helper"

class CrateStrongTest < ActiveSupport::TestCase
  def test_blank_label_is_rejected
    crate = Crate.new(label: "")
    refute crate.valid?
    assert_includes crate.errors[:label], "can't be blank"
  end

  def test_destroying_a_crate_destroys_its_items
    crate = Crate.create!(label: "box")
    crate.crate_items.create!
    crate.destroy!
    assert_equal 0, CrateItem.count
  end
end
