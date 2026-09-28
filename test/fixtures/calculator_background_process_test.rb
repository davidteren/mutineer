# frozen_string_literal: true

require "minitest/autorun"
require_relative "calculator"

# Passing suite that leaves two processes running after its test ends: one
# started with `spawn` (exec) and one with `fork` (no exec). Each writes its
# pid to MUTINEER_BACKGROUND_PIDS when set, so the caller can stop them.
class CalculatorBackgroundProcessTest < Minitest::Test
  def test_add
    pids = [Process.spawn("sleep", "60", out: File::NULL, err: File::NULL)]
    pids << fork { sleep 60; exit!(0) } # rubocop:disable Style/Semicolon
    pids.each { |pid| Process.detach(pid) }
    if (file = ENV["MUTINEER_BACKGROUND_PIDS"])
      File.open(file, "a") { |f| f.puts(pids) }
    end
    assert_equal 5, Calculator.new.add(2, 3)
  end
end
