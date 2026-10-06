# frozen_string_literal: true

require "minitest/autorun"

# The first test fails; then MUTINEER_FIXTURE_MODE picks how the run ends: in
# the class wrapper after `super`, in a later test, or in a later class. A
# --matrix run must give the verdict a run without it gives (#191).
class MatrixExitAfterKillFixture < Minitest::Test
  i_suck_and_my_tests_are_order_dependent!

  def self.after_tests(result)
    case ENV.fetch("MUTINEER_FIXTURE_MODE", nil)
    when "wrapper_exit" then exit 0
    when "wrapper_raise" then raise "the wrapper raised"
    end
    result
  end

  # A class-level step that runs once per test: it ends the run on the
  # later test.
  def self.before_test(method_name)
    exit!(0) if method_name.to_s == "test_b_later" && ENV.fetch("MUTINEER_FIXTURE_MODE", nil) == "per_test_exit"
  end

  # Minitest 6 runs a test class in `run_suite` and each test in
  # `run(klass, name, reporter)`; Minitest 5 uses `run` and `run_one_method`.
  if Minitest::Runnable.respond_to?(:run_suite)
    def self.run_suite(*args)
      after_tests(super)
    end

    def self.run(klass, method_name, reporter)
      before_test(method_name)
      super
    end
  else
    def self.run(*args)
      after_tests(super)
    end

    def self.run_one_method(klass, method_name, reporter)
      before_test(method_name)
      super
    end
  end

  def test_a_fails
    flunk "the first test fails"
  end

  def test_b_later
    exit 0 if ENV.fetch("MUTINEER_FIXTURE_MODE", nil) == "later_exit"
    exit 2 if ENV.fetch("MUTINEER_FIXTURE_MODE", nil) == "later_exit_two"
    pass
  end
end

# Serial classes run before `parallelize_me!` classes, so this one runs last.
class MatrixExitAfterKillLaterClassFixture < Minitest::Test
  parallelize_me!

  def test_later_class
    exit 0 if ENV.fetch("MUTINEER_FIXTURE_MODE", nil) == "later_class_exit"
    pass
  end
end
