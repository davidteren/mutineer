# frozen_string_literal: true

require "minitest/autorun"

# A class-level wrapper cleans up after `super`, not in an `ensure`, like
# `transaction { super; raise ActiveRecord::Rollback }`.
class StopAtFirstFailureCleanupFixture < Minitest::Test
  i_suck_and_my_tests_are_order_dependent!

  # Minitest 6 runs a test class in `run_suite`, Minitest 5 in `run`.
  if Minitest::Runnable.respond_to?(:run_suite)
    def self.run_suite(*args)
      result = super
      File.write("#{ENV.fetch('MUTINEER_FIXTURE_MARKER')}.cleanup", "ran")
      result
    end
  else
    def self.run(*args)
      result = super
      File.write("#{ENV.fetch('MUTINEER_FIXTURE_MARKER')}.cleanup", "ran")
      result
    end
  end

  def test_a_fails
    flunk "the first test fails"
  end

  def test_b_writes_marker
    File.write(ENV.fetch("MUTINEER_FIXTURE_MARKER"), "ran")
    pass
  end
end
