# frozen_string_literal: true

require_relative "test_helper"

# #315: the gem ships the agent skill and opts in as a Rails Hyperdrive
# companion, so `bin/rails hyperdrive:init` installs the skill into a Rails app.
# CI builds the gem but never looks inside it; this pins what the gemspec packages.
class GemspecTest < Minitest::Test
  SPEC = Gem::Specification.load("mutineer.gemspec")

  def test_ships_the_agent_skill
    assert_includes SPEC.files, "skills/mutineer/SKILL.md"
  end

  def test_opts_in_as_a_rails_hyperdrive_companion
    refute_empty SPEC.metadata["hyperdrive_targets"].to_s
  end
end
