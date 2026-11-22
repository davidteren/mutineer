# frozen_string_literal: true

require "test_helper"
require "load_path_probe"

# Needs extra_load_path/ on $LOAD_PATH (#491). The name avoids order_*_test.rb,
# so no paired run picks it up for app/models/order.rb.
class LoadPathProbeTest < ActiveSupport::TestCase
  def test_subtotal_matches_the_probe
    # Mutineer's own daemon test reads this, to prove the user's RUBYOPT
    # did not reach the daemon (#100).
    File.write(ENV["LOAD_PATH_PROBE_ENV_LOG"], ENV["RUBYOPT"].to_s) if ENV["LOAD_PATH_PROBE_ENV_LOG"]
    assert_equal LoadPathProbe::SMALL_SUBTOTAL_CENTS, orders(:small).subtotal_cents
  end
end
