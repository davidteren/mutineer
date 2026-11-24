# frozen_string_literal: true

require_relative "test_helper"
require "open3"
require "json"

# Real ActiveSupport callbacks, from the Rails fixture bundle. The zero-dep
# suite stands in for these objects. This checks that stand-in against Rails'
# own chain: a Proc skip picks up the reloaded Proc, and an independent
# callback that names the parent's symbol does not. A class body that calls
# `define_callbacks` keeps its concern's callbacks across a reload (#504).
class RailsCallbackRestoreTest < Minitest::Test
  APP = File.expand_path("fixtures/rails_app", __dir__)
  PROBE = File.expand_path("support/rails_callback_restore_probe.rb", __dir__)

  def test_a_real_rails_skip_carries_a_proc_and_keeps_an_independent_symbol
    env = ENV.to_h
    env.keys.each do |key|
      env.delete(key) if key.start_with?("BUNDLE_", "BUNDLER_") || key.start_with?("GEM_")
    end
    %w[RUBYOPT RUBYLIB].each { |key| env.delete(key) }
    env["BUNDLE_GEMFILE"] = File.join(APP, "Gemfile")
    out, err, status = Open3.capture3(env, "bundle", "exec", "ruby", PROBE, chdir: APP)
    assert status.success?, "#{err}\n#{out}"

    result = JSON.parse(out)
    assert result.fetch("proc_skip").fetch("new_proc")
    refute result.fetch("proc_skip").fetch("old_proc")
    assert result.fetch("proc_skip").fetch("express")
    assert result.fetch("independent_symbol").fetch("exact_active")
    refute result.fetch("independent_symbol").fetch("exact_ready")
    assert_equal %w[active? mine?], result.fetch("independent_symbol").fetch("longer")

    # #504: probe P4 of the plan. A class body that calls `define_callbacks`
    # keeps the callbacks of its concern and of a subclass in another file. Only
    # OwnDoubled grows, because the concern and the body add the same `&:stamp`,
    # and the #479 log names it.
    own = result.fetch("own_chains")
    assert_equal({ "OwnChain" => 2, "OwnChild" => 3, "OwnDoubled" => 2, "OwnModel" => 2 }, own.fetch("before"))
    assert_equal({ "OwnChain" => 2, "OwnChild" => 3, "OwnDoubled" => 3, "OwnModel" => 2 }, own.fetch("after"))
    assert_equal %w[stamp own], own.fetch("log_before")
    assert_equal %w[stamp own], own.fetch("log_after")
    assert_equal %w[stamp own child], own.fetch("child_log_after")
    assert_equal %w[OwnDoubled], own.fetch("grown")

    # #543: probe P8 of the plan. One mutant load must not add a conditional
    # skip's condition a second time when every class kept its old callback
    # entry. QuietOwn adds its own conditioned callback, so it has two before
    # and after. GrandNote adds the callback again before ChildNote's skip, so
    # Rails must run that skip, and ChildNote gets a second condition, as
    # before #543 (#578).
    skips = result.fetch("conditional_skips")
    assert_equal({ "QuietConcern" => 1, "QuietChild" => 1, "QuietLambda" => 1, "QuietOwn" => 2,
                   "ChildNote" => 1, "GrandNote" => 1, "ProbeChild" => 1 }, skips.fetch("before"))
    assert_equal({ "QuietConcern" => 1, "QuietChild" => 1, "QuietLambda" => 1, "QuietOwn" => 2,
                   "ChildNote" => 2, "GrandNote" => 1, "ProbeChild" => 1 }, skips.fetch("after"))
    quiet = { "QuietConcern" => %w[quiet? stamp], "QuietChild" => %w[quiet? stamp], "QuietLambda" => %w[quiet? stamp] }
    assert_equal quiet, skips.fetch("logs_before")
    assert_equal quiet, skips.fetch("logs_after")
    assert skips.fetch("typo_raises"), "a conditional skip of a name with no callback still raises"
  end
end
