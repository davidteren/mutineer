# frozen_string_literal: true

# RSpec stops early and returns normally, as after a first Ctrl-C, so the last
# example never runs (#191).
RSpec.describe "quit mid run" do
  it("asks RSpec to quit") { RSpec.world.wants_to_quit = true }
  it("is never run") { expect(1).to eq(1) }
end
