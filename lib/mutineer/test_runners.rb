# frozen_string_literal: true

require_relative "test_runners/minitest"
require_relative "test_runners/rspec"

module Mutineer
  # Picks the test-framework runner. Each runner responds to `.run(files) -> 0/1`
  # (0 = all passed, 1 = any failure) and is called only inside a forked child.
  module TestRunners
    def self.for(framework)
      case framework
      when "rspec" then RSpec
      when "minitest", nil, "" then Minitest
      else
        raise Mutineer::ConfigError, "unknown framework #{framework.inspect} (expected: minitest, rspec)"
      end
    end
  end
end
