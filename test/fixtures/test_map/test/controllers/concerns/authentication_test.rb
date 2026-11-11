# frozen_string_literal: true

require "minitest/autorun"
require_relative "../../../app/controllers/concerns/authentication"

class AuthenticationTest < Minitest::Test
  class Host
    include Authentication
  end

  def test_signed_in_offset
    assert_equal 2, Host.new.signed_in_offset(1)
  end
end
