# frozen_string_literal: true

require "minitest/autorun"

# `parallelize_me!` records results on worker threads.
class StopAtFirstFailureParallelFixture < Minitest::Test
  parallelize_me!

  def test_fails
    flunk "a failure on a worker thread"
  end

  def test_writes_marker
    File.write(ENV.fetch("MUTINEER_FIXTURE_MARKER"), "ran")
    pass
  end
end
