# frozen_string_literal: true

$LOAD_PATH.unshift File.expand_path("../lib", __dir__)

require "minitest/autorun"
require "mutineer"

# A commit can start git's auto-maintenance as a detached background process.
# In a test's temp repo it can still write into .git while Dir.mktmpdir deletes
# the directory, which fails the test with ENOTEMPTY (#174). Turn it off for
# every git process the suite starts, after any GIT_CONFIG_* entries already set.
git_config_count = ENV.fetch("GIT_CONFIG_COUNT", "0").to_i
ENV["GIT_CONFIG_KEY_#{git_config_count}"] = "maintenance.auto"
ENV["GIT_CONFIG_VALUE_#{git_config_count}"] = "false"
ENV["GIT_CONFIG_COUNT"] = (git_config_count + 1).to_s
