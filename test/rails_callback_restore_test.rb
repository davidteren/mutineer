# frozen_string_literal: true

require_relative "test_helper"
require "open3"
require "json"

# Real ActiveSupport callbacks, from the Rails fixture bundle. The zero-dep
# suite stands in for these objects. This checks that stand-in against Rails'
# own chain: a Proc skip picks up the reloaded Proc, and an independent
# callback that names the parent's symbol does not.
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
  end
end
