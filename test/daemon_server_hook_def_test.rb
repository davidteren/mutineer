# frozen_string_literal: true

require_relative "test_helper"
require "json"
require "mutineer/daemon_server"
require "mutineer/isolation"
require "mutineer/job_plan"

# #297: the daemon child loads the mutant file, then places the stored
# hook-block def into each class that already has the method. Each test runs
# the payload in a fork, as the daemon does, so this process keeps the original.
class DaemonServerHookDefTest < Minitest::Test
  FIXTURE = File.expand_path("fixtures/singleton/concern_class_methods.rb", __dir__)

  # The concern whose hosts include wrappers and an object's singleton class.
  EDGE_FIXTURE = File.expand_path("fixtures/singleton/hook_edges.rb", __dir__)

  # The payload the backend sends for `ConcernPricing#doubled` with its body
  # replaced, after a trip through JSON as on the wire.
  def payload(replacement, fixture: FIXTURE, only: "ConcernPricing#doubled")
    source = File.read(fixture)
    subject = Mutineer::Project.discover([fixture], only: only).first
    body = subject.body_loc
    mutation = Mutineer::Mutation.new(start_offset: body.start_offset, end_offset: body.end_offset,
                                      replacement: replacement, operator: "test")
    code, hook_def = Mutineer::JobPlan.hook_mutant(mutation.apply(source), mutation, subject, source)
    JSON.parse(JSON.generate("code" => code, "source_file" => fixture, "hook_def" => hook_def))
  end

  def test_apply_payload_places_the_hook_def
    sent = payload("x * 5")
    result = Mutineer::Isolation.run do
      require FIXTURE
      Mutineer::DaemonServer.send(:apply_payload, sent)
      ConcernProduct.new.doubled(2) == 10 ? 0 : 1
    end
    assert_predicate result, :survived?, "the existing class must get the mutated def"
  end

  def test_apply_payload_raises_when_the_hook_def_did_not_load
    sent = payload("x * 5").merge("code" => "# no stored def\n")
    result = Mutineer::Isolation.run do
      $stderr.reopen(File::NULL)
      Mutineer::DaemonServer.send(:apply_payload, sent)
      0
    end
    assert_predicate result, :error?
  end

  def test_apply_payload_places_a_hook_def_beneath_a_prepended_wrapper
    sent = payload("x * 5", fixture: EDGE_FIXTURE, only: "HookEdges#bumped")
    result = Mutineer::Isolation.run do
      require_relative "fixtures/singleton/hook_edges_hosts"
      Mutineer::DaemonServer.send(:apply_payload, sent)
      HookEdgesWrappedHost.new.bumped(2) == 10 ? 0 : 1
    end
    assert_predicate result, :survived?, "the wrapper must call the mutated method through super"
  end

  def test_apply_payload_places_a_singleton_hook_def_beneath_a_prepended_wrapper
    sent = payload("STEP + 9", fixture: EDGE_FIXTURE, only: "HookEdges.made")
    result = Mutineer::Isolation.run do
      require_relative "fixtures/singleton/hook_edges_hosts"
      Mutineer::DaemonServer.send(:apply_payload, sent)
      HookEdgesWrappedHost.made == 10 ? 0 : 1
    end
    assert_predicate result, :survived?, "the singleton wrapper must call the mutated method through super"
  end

  def test_apply_payload_places_a_hook_def_on_a_singleton_class_host
    sent = payload("x * 5", fixture: EDGE_FIXTURE, only: "HookEdges#bumped")
    result = Mutineer::Isolation.run do
      require_relative "fixtures/singleton/hook_edges_hosts"
      Mutineer::DaemonServer.send(:apply_payload, sent)
      HOOK_EDGES_OBJECT.bumped(2) == 10 ? 0 : 1
    end
    assert_predicate result, :survived?, "the object must dispatch to its singleton class's mutated method"
  end

  def test_apply_payload_scores_an_aliased_wrapper_as_error
    sent = payload("x * 5")
    result = Mutineer::Isolation.run do
      require FIXTURE
      ConcernProduct.class_eval do
        alias_method :old_doubled, :doubled
        def doubled(x) = old_doubled(x)
      end
      Mutineer::DaemonServer.send(:apply_payload, sent)
      ConcernProduct.new.doubled(2) == 4 ? 0 : 1
    end
    assert_predicate result, :error?, "the original body retained by an alias must not score survived"
  end
end
