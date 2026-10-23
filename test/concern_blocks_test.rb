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
  CONCERNS = %i[TaggedForget TaggedOther WrappedForget GuardedForget ReplacedForget].freeze

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
end
