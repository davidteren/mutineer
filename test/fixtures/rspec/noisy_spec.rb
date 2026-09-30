# frozen_string_literal: true

# Passing spec that prints to both streams, so the RSpec runner's silencing of
# spec output (not only its formatter) can be asserted.
RSpec.describe "noisy example" do
  it "prints" do
    puts "NOISE-ON-STDOUT"
    warn "NOISE-ON-STDERR"
    expect(1 + 1).to eq(2)
  end
end
