# frozen_string_literal: true

require "minitest/autorun"
require_relative "binary_body"

# One example, as in issue #434. The failure message holds the return value
# as raw bytes, which is what Rails' `assert_response` does with a short body
# (`ActionDispatch::Assertions::ResponseAssertions#response_body_if_short`).
# `assert_equal` would `inspect` the bytes, and that message is valid UTF-8.
class BinaryBodyTest < Minitest::Test
  def test_missing_blob_is_not_found
    body = BinaryBody.new.show("missing")
    return if body == :not_found

    flunk(+"expected not_found\nResponse body: #{body}")
  end
end
