# frozen_string_literal: true

require "minitest/autorun"
require_relative "../../../app/models/concerns/storage/totaled"

class TotaledTest < Minitest::Test
  include Storage::Totaled

  def test_total
    assert_equal 5, total(2, 3)
  end
end
