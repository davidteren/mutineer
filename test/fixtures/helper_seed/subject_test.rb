# frozen_string_literal: true

require "json"
require "minitest/autorun"
require_relative "test_helper"
require_relative "subject"

# Seed 1 puts beta before epsilon; seed 99 reverses them on Minitest 5 and 6.
# Every test calls value, but no test asserts it. A false kill is an order bug.
class HelperSeedSubjectTest < Minitest::Test
  def record(label)
    row = { label: label, seed: Minitest.seed, value: HelperSeedSubject.value }
    File.open(ENV.fetch("MUTINEER_HELPER_SEED_LOG"), "a") { |file| file.puts(JSON.generate(row)) }
  end

  def test_alpha = (record("alpha"); assert true)
  def test_beta = (record("beta"); $mutineer_helper_seed_ready = true; assert true)
  def test_gamma = (record("gamma"); assert true)
  def test_delta = (record("delta"); assert true)
  def test_epsilon = (record("epsilon"); assert $mutineer_helper_seed_ready, "beta must run before epsilon")
  def test_zeta = (record("zeta"); assert true)
end
