# frozen_string_literal: true

require "minitest/autorun"

# Serial classes run before `parallelize_me!` classes, so the failing class
# runs first. The later class writes its marker before `super`.
class StopAtFirstFailureFirstClassFixture < Minitest::Test
  def test_fails
    flunk "the first class fails"
  end
end

class StopAtFirstFailureLaterClassFixture < Minitest::Test
  parallelize_me!

  # Minitest 6 runs a test class in `run_suite`, Minitest 5 in `run`.
  if Minitest::Runnable.respond_to?(:run_suite)
    def self.run_suite(*args)
      File.write(ENV.fetch("MUTINEER_FIXTURE_MARKER"), "setup ran")
      super
    end
  else
    def self.run(*args)
      File.write(ENV.fetch("MUTINEER_FIXTURE_MARKER"), "setup ran")
      super
    end
  end

  def test_passes
    pass
  end
end
