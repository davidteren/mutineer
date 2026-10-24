# frozen_string_literal: true

require "minitest/autorun"

# The hosts must exist before the mutant loads, or every host is a lazy
# includer and these tests prove nothing about placement (#297).
raise "load hook_edges_hosts.rb before this test (require_paths)" unless defined?(HOOK_EDGES_ANONYMOUS)

class HookEdgesTest < Minitest::Test
  def test_named_host
    assert_equal 3, HookEdgesHost.new.bumped(2)
    assert_equal 4, HookEdgesHost.new.bumped(3)
  end

  def test_override_keeps_its_own
    assert_equal 102, HookEdgesOverride.new.bumped(2)
  end

  def test_anonymous_host
    assert_equal 3, HOOK_EDGES_ANONYMOUS.first.new.bumped(2)
    assert_equal 4, HOOK_EDGES_ANONYMOUS.first.new.bumped(3)
  end

  def test_mixin_host
    assert_equal 3, HookEdgesMixinHost.new.bumped(2)
    assert_equal 4, HookEdgesMixinHost.new.bumped(3)
  end

  def test_lazy_host
    host = Class.new { include HookEdges }
    assert_equal 3, host.new.bumped(2)
    assert_equal 4, host.new.bumped(3)
  end

  def test_singleton_defs
    assert_equal 7, HookEdgesHost.made
    assert_equal 6, HookEdgesHost.tagged(3)
    assert_equal 8, HookEdgesHost.tagged(4)
  end

  def test_private_def
    assert_equal 4, HookEdgesHost.new.revealed(5)
    assert_equal 6, HookEdgesHost.new.revealed(7)
    assert HookEdgesHost.private_method_defined?(:secret)
  end

  def test_registered_once
    assert_equal 1, HookEdges::REGISTRY.count(HookEdgesHost)
  end
end
