# frozen_string_literal: true

require_relative "binary_body"

# The RSpec form of test/fixtures/binary_body_test.rb. The failure message
# holds the return value as raw bytes, as Rails' `assert_response` does.
RSpec.describe BinaryBody do
  it "reports a missing blob as not found" do
    body = BinaryBody.new.show("missing")
    expect(body).to eq(:not_found), +"expected not_found\nResponse body: #{body}"
  end
end
