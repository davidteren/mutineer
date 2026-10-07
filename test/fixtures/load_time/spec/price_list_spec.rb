# frozen_string_literal: true

require_relative "../setup/price_table"

RSpec.describe "PRICE_TABLE" do
  it "holds the prices built at load" do
    expect(PRICE_TABLE).to eq([6])
  end
end
