# frozen_string_literal: true

require "minitest/autorun"

# Writes the Minitest seed of the run to MUTINEER_FIXTURE_MARKER.
class StopAtFirstFailureSeedFixture < Minitest::Test
  def test_writes_seed
    File.write(ENV.fetch("MUTINEER_FIXTURE_MARKER"), Minitest.seed.to_s)
    pass
  end
end
