# frozen_string_literal: true

require "minitest/autorun"

# Each test runs and records in a new Fiber, as async runner wrappers do.
module StopAtFirstFailureFiberRun
  # Minitest 5 runs and records one test in `Runnable.run_one_method`.
  def run_one_method(*args)
    Fiber.new { super(*args) }.resume
  end

  # Minitest 6 runs one test in the three-argument `Runnable.run`.
  def run(*args)
    return super(*args) unless args.size == 3

    Fiber.new { super(*args) }.resume
  end
end
Minitest::Runnable.singleton_class.prepend(StopAtFirstFailureFiberRun)

class StopAtFirstFailureFiberFixture < Minitest::Test
  i_suck_and_my_tests_are_order_dependent!

  def test_a_fails
    flunk "a failure in a fiber"
  end

  def test_b_writes_marker
    File.write(ENV.fetch("MUTINEER_FIXTURE_MARKER"), "ran")
    pass
  end
end
