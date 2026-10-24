# frozen_string_literal: true

require_relative "test_helper"
require_relative "fixtures/singleton/concern_stub"
require "tmpdir"

# #256: reload loads a mutant from a temp file, and ActiveSupport rejects a
# second `included` block from another file. ConcernBlocks.forget removes the
# blocks the source file stored, so the mutant's load stores its own.
class ConcernBlocksTest < Minitest::Test
  # The concerns these tests define, removed after each test so a second run
  # in the same process starts with no stored block.
  CONCERNS = %i[TaggedForget TaggedOther WrappedForget GuardedForget ReplacedForget HookPlaced HookPlacedHost].freeze

  def teardown
    CONCERNS.each { |name| Object.send(:remove_const, name) if Object.const_defined?(name, false) }
  end

  def concern_source(name)
    <<~RUBY
      module #{name}
        extend ActiveSupport::Concern
        included do
          def tag = :original
        end
      end
    RUBY
  end

  def test_a_second_included_block_loads_after_forget
    Dir.mktmpdir("mutineer-concern") do |dir|
      source = File.join(dir, "tagged_forget.rb")
      copy = File.join(dir, "mutant.rb")
      File.write(source, concern_source("TaggedForget"))
      File.write(copy, concern_source("TaggedForget"))
      load source
      assert_raises(ActiveSupport::Concern::MultipleIncludedBlocks) { load copy }

      Mutineer::ConcernBlocks.forget(source)
      load copy
      assert_equal copy, TaggedForget.instance_variable_get(:@_included_block).source_location.first
    end
  end

  # A concern the mutant's load skips (an `unless defined?` guard) stores no
  # new block, so replace puts the original back: a class that includes the
  # concern during the tests still gets what the block defines.
  def test_replace_restores_a_block_the_load_did_not_store_again
    Dir.mktmpdir("mutineer-concern") do |dir|
      source = File.join(dir, "guarded_forget.rb")
      copy = File.join(dir, "mutant.rb")
      code = "unless defined?(GuardedForget)\n#{concern_source("GuardedForget")}end\n"
      File.write(source, code)
      File.write(copy, code)
      load source
      original = GuardedForget.instance_variable_get(:@_included_block)

      Mutineer::ConcernBlocks.replace(source) { load copy }
      assert_same original, GuardedForget.instance_variable_get(:@_included_block)
      assert_equal :original, Class.new { include GuardedForget }.new.tag
    end
  end

  # A load that stores its own block keeps it; the original does not come back.
  def test_replace_keeps_the_block_the_load_stored
    Dir.mktmpdir("mutineer-concern") do |dir|
      source = File.join(dir, "replaced_forget.rb")
      copy = File.join(dir, "mutant.rb")
      File.write(source, concern_source("ReplacedForget"))
      File.write(copy, concern_source("ReplacedForget"))
      load source
      Mutineer::ConcernBlocks.replace(source) { load copy }
      assert_equal copy, ReplacedForget.instance_variable_get(:@_included_block).source_location.first
    end
  end

  def test_blocks_from_other_files_stay
    Dir.mktmpdir("mutineer-concern") do |dir|
      other = File.join(dir, "tagged_other.rb")
      File.write(other, concern_source("TaggedOther"))
      load other
      Mutineer::ConcernBlocks.forget(File.join(dir, "unrelated.rb"))
      assert TaggedOther.instance_variable_defined?(:@_included_block)
    end
  end

  # A prepended block is stored the same way and is forgotten too.
  def test_a_second_prepended_block_loads_after_forget
    Dir.mktmpdir("mutineer-concern") do |dir|
      source = File.join(dir, "wrapped_forget.rb")
      copy = File.join(dir, "mutant.rb")
      code = "module WrappedForget\n  extend ActiveSupport::Concern\n  prepended do\n    def wrap = :original\n  end\nend\n"
      File.write(source, code)
      File.write(copy, code)
      load source
      assert_raises(ActiveSupport::Concern::MultiplePrependBlocks) { load copy }

      Mutineer::ConcernBlocks.forget(source)
      load copy
      assert_equal copy, WrappedForget.instance_variable_get(:@_prepended_block).source_location.first
    end
  end

  # #297: writes a concern whose `included` block holds `body`, loads it, and
  # yields the file and the first line of the block body.
  def with_hook_concern(body)
    Dir.mktmpdir("mutineer-hook") do |dir|
      source = File.join(dir, "hook_placed.rb")
      File.write(source, "module HookPlaced\n  extend ActiveSupport::Concern\n  included do\n#{body}\n  end\nend\n")
      load source
      yield source, 4
    ensure
      Mutineer::ConcernBlocks.instance_variable_set(:@hook_def, nil)
    end
  end

  def place(source, line, name, singleton: false)
    Mutineer::ConcernBlocks.place_hook_def(source_file: source, line: line, name: name, singleton: singleton)
  end

  def test_place_hook_def_reaches_named_and_anonymous_owners
    with_hook_concern("def tag = :original") do |source, line|
      named = Object.const_set(:HookPlacedHost, Class.new { include HookPlaced })
      anonymous = Class.new { include HookPlaced }
      mixin = Module.new { include HookPlaced }
      through = Class.new { include mixin }
      Mutineer::ConcernBlocks.store_hook_def { def tag = :mutant }

      assert_equal 3, place(source, line, :tag)
      assert_equal :mutant, named.new.tag
      assert_equal :mutant, anonymous.new.tag
      assert mixin.method_defined?(:tag, false)
      assert_equal :mutant, through.new.tag
      refute through.method_defined?(:tag, false)
    end
  end

  def test_place_hook_def_skips_an_override_and_an_inheritor
    with_hook_concern("def tag = :original") do |source, line|
      host = Class.new { include HookPlaced }
      override = Class.new(host) { def tag = :override }
      inheritor = Class.new(host)
      Mutineer::ConcernBlocks.store_hook_def { def tag = :mutant }

      assert_equal 1, place(source, line, :tag)
      assert_equal :override, override.new.tag
      assert_equal :mutant, inheritor.new.tag
      refute inheritor.method_defined?(:tag, false)
    end
  end

  def test_place_hook_def_keeps_private_visibility
    with_hook_concern("private\ndef secret = :original") do |source, _line|
      host = Class.new { include HookPlaced }
      Mutineer::ConcernBlocks.store_hook_def { def secret = :mutant }

      assert_equal 1, place(source, 5, :secret)
      assert host.private_method_defined?(:secret, false)
      assert_equal :mutant, host.new.send(:secret)
    end
  end

  def test_place_hook_def_keeps_protected_visibility
    with_hook_concern("protected\ndef secret = :original") do |source, _line|
      host = Class.new { include HookPlaced }
      Mutineer::ConcernBlocks.store_hook_def { def secret = :mutant }

      assert_equal 1, place(source, 5, :secret)
      assert host.protected_method_defined?(:secret, false)
      assert_equal :mutant, host.new.send(:secret)
    end
  end

  def test_place_hook_def_targets_singleton_defs
    with_hook_concern("def self.made = :original\nclass << self\ndef tagged = :original\nend") do |source, line|
      hosts = [Class.new { include HookPlaced }, Class.new { include HookPlaced }]
      Mutineer::ConcernBlocks.store_hook_def { def self.made = :mutant }
      assert_equal 2, place(source, line, :made, singleton: true)
      Mutineer::ConcernBlocks.store_hook_def do
        class << self
          def tagged = :mutant
        end
      end
      assert_equal 2, place(source, 6, :tagged, singleton: true)

      hosts.each do |host|
        assert_equal %i[mutant mutant], [host.made, host.tagged]
        refute host.method_defined?(:made)
      end
    end
  end

  def test_place_hook_def_keeps_a_private_singleton_def_private
    with_hook_concern("class << self\nprivate\ndef hidden = :original\nend") do |source, _line|
      host = Class.new { include HookPlaced }
      Mutineer::ConcernBlocks.store_hook_def do
        class << self
          def hidden = :mutant
        end
      end

      assert_equal 1, place(source, 6, :hidden, singleton: true)
      assert host.singleton_class.private_method_defined?(:hidden, false)
      assert_equal :mutant, host.send(:hidden)
    end
  end

  def test_place_hook_def_raises_without_a_stored_def
    with_hook_concern("def tag = :original") do |source, line|
      error = assert_raises(RuntimeError) { place(source, line, :tag) }
      assert_includes error.message, "tag (#{source}:#{line})"
      assert_includes error.message, "did not reach its included or prepended call"
    end
  end

  def test_place_hook_def_raises_when_an_owner_aliased_the_method
    with_hook_concern("def tag = :original") do |source, line|
      host = Class.new do
        include HookPlaced
        alias_method :old_tag, :tag
      end
      Mutineer::ConcernBlocks.store_hook_def { def tag = :mutant }

      error = assert_raises(RuntimeError) { place(source, line, :tag) }
      assert_includes error.message, "#old_tag is an alias of it"
      assert_equal :original, host.new.tag
    end
  end

  def test_place_hook_def_raises_when_a_subclass_aliased_the_method
    with_hook_concern("def tag = :original") do |source, line|
      host = Class.new { include HookPlaced }
      Class.new(host) { alias_method :base_tag, :tag }
      Mutineer::ConcernBlocks.store_hook_def { def tag = :mutant }

      error = assert_raises(RuntimeError) { place(source, line, :tag) }
      assert_includes error.message, "#base_tag is an alias of it"
    end
  end

  # A wrapper can replace the current name while an alias keeps the original.
  # Check this before changing any ordinary owner, even when there are none.
  def assert_aliased_wrapper_rejected(singleton:, ordinary:)
    definition = singleton ? "def self.tag = :original" : "def tag = :original"
    with_hook_concern(definition) do |source, line|
      wrapped = Class.new { include HookPlaced }
      target = singleton ? wrapped.singleton_class : wrapped
      target.class_eval do
        alias_method :old_tag, :tag
        private :old_tag
        def tag = old_tag
      end
      plain = Class.new { include HookPlaced } if ordinary
      if singleton
        Mutineer::ConcernBlocks.store_hook_def { def self.tag = :mutant }
      else
        Mutineer::ConcernBlocks.store_hook_def { def tag = :mutant }
      end

      error = assert_raises(RuntimeError) { place(source, line, :tag, singleton: singleton) }
      assert_includes error.message, "old_tag is an alias of it"
      assert_equal :original, singleton ? wrapped.tag : wrapped.new.tag
      assert_equal :original, singleton ? plain.tag : plain.new.tag if plain
    end
  end

  def test_place_hook_def_rejects_an_aliased_wrapper_without_an_owner
    assert_aliased_wrapper_rejected(singleton: false, ordinary: false)
  end

  def test_place_hook_def_rejects_an_aliased_wrapper_beside_an_owner
    assert_aliased_wrapper_rejected(singleton: false, ordinary: true)
  end

  def test_place_hook_def_rejects_a_singleton_aliased_wrapper_without_an_owner
    assert_aliased_wrapper_rejected(singleton: true, ordinary: false)
  end

  def test_place_hook_def_rejects_a_singleton_aliased_wrapper_beside_an_owner
    assert_aliased_wrapper_rejected(singleton: true, ordinary: true)
  end

  def test_reload_scores_an_aliased_wrapper_as_error
    with_hook_concern("def tag\n  :original\nend") do |source, _line|
      Object.const_set(:HookPlacedHost, Class.new do
        include HookPlaced
        alias_method :old_tag, :tag
        def tag = old_tag
      end)
      test_file = File.join(File.dirname(source), "hook_placed_test.rb")
      File.write(test_file, <<~RUBY)
        require "minitest/autorun"
        class HookAliasedWrapperTest < Minitest::Test
          def test_tag
            assert_equal :original, HookPlacedHost.new.tag
          end
        end
      RUBY
      subject = Mutineer::Project.discover([source]).first
      body = subject.body_loc
      mutation = Mutineer::Mutation.new(start_offset: body.start_offset, end_offset: body.end_offset,
                                        replacement: ":mutant", operator: "test")
      map = Mutineer::CoverageMap.from_data(map: { "hook_placed.rb:#{body.start_line}" => ["hook_placed_test.rb"] },
                                           failed_test_files: [], project_root: File.dirname(source))
      result = Mutineer::Runner.run(mutation, source_file: source, subject: subject,
                                             strategy: "reload", coverage_map: map)
      assert_predicate result, :error?, "a wrapper that keeps the original must not score survived"
    end
  end

  def test_place_hook_def_with_no_owner_is_a_no_op
    with_hook_concern("def tag = :original") do |source, line|
      Mutineer::ConcernBlocks.store_hook_def { def tag = :mutant }
      assert_equal 0, place(source, line, :tag)
      # The stored def was taken, so a second placement has none.
      assert_raises(RuntimeError) { place(source, line, :tag) }
    end
  end
end
