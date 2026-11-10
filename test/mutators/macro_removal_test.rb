# frozen_string_literal: true

require_relative "../test_helper"
require "tempfile"

class MacroRemovalTest < Minitest::Test
  def with_source(source)
    Tempfile.create(["macro", ".rb"]) do |file|
      file.write(source)
      file.flush
      yield file.path, source
    end
  end

  def macro_subjects(path)
    Mutineer::Project.discover([path], macros: true).select(&:macro?)
  end

  def test_removes_each_listed_macro
    source = <<~RUBY
      class Card
        validates :title, presence: true
        has_many :entropies, dependent: :destroy
        before_save { x }
        scope :active, -> { where(active: true) }
      end
    RUBY
    with_source(source) do |path, text|
      subjects = macro_subjects(path)
      assert_equal 4, subjects.size
      subjects.each do |subject|
        mutations = Mutineer::Mutators::MacroRemoval.new.mutations_for(subject, text)
        assert_equal 1, mutations.size, subject.qualified_name
        mutation = mutations.first
        assert_equal :macro_removal, mutation.operator
        assert_equal "nil", mutation.replacement
        assert_equal subject.macro_node.location.slice, text.byteslice(mutation.start_offset...mutation.end_offset)
        assert mutation.valid?(text), subject.qualified_name
      end
    end
  end

  def test_gives_nothing_for_a_def_subject
    source = "class Card\n  def total(a, b)\n    a + b\n  end\nend\n"
    with_source(source) do |path, text|
      subject = Mutineer::Project.discover([path]).first
      assert_empty Mutineer::Mutators::MacroRemoval.new.mutations_for(subject, text)
    end
  end

  def test_declines_a_heredoc_split
    source = <<~RUBY
      class Card
        validates :name, format: { with: <<~RE }
          hi
        RE
      end
    RUBY
    with_source(source) do |path, text|
      subject = macro_subjects(path).first
      operator = Mutineer::Mutators::MacroRemoval.new
      assert_empty operator.mutations_for(subject, text)
      assert_equal 1, operator.declined
    end
  end
end
