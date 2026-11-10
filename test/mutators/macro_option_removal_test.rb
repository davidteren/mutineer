# frozen_string_literal: true

require_relative "../test_helper"
require "tempfile"

class MacroOptionRemovalTest < Minitest::Test
  def with_source(source)
    Tempfile.create(["macro-opt", ".rb"]) do |file|
      file.write(source)
      file.flush
      yield file.path, source
    end
  end

  def macro_subjects(path)
    Mutineer::Project.discover([path], macros: true).select(&:macro?)
  end

  def mutations_for(source)
    with_source(source) do |path, text|
      subject = macro_subjects(path).first
      operator = Mutineer::Mutators::MacroOptionRemoval.new
      return [operator.mutations_for(subject, text), operator.declined, text]
    end
  end

  def test_replaces_each_keyword_option
    source = "class Box\n  has_many :parts, dependent: :destroy, inverse_of: :box\nend\n"
    mutations, declined, text = mutations_for(source)
    assert_equal 0, declined
    assert_equal 2, mutations.size
    applied = mutations.map { |mutation| mutation.apply(text) }
    assert_includes applied, source.sub("dependent: :destroy", "**{}")
    assert_includes applied, source.sub("inverse_of: :box", "**{}")
    mutations.each { |mutation| assert mutation.valid?(text) }
  end

  def test_option_removal_starts_on_the_pair_line
    source = <<~RUBY
      class Box
        has_many :parts,
          dependent: :destroy,
          inverse_of: :box
      end
    RUBY
    mutations, = mutations_for(source)
    dependent = mutations.find { |mutation| source.byteslice(mutation.start_offset...mutation.end_offset).include?("dependent") }
    pair_line = source.lines.index { |line| line.include?("dependent:") } + 1
    start_line = source.byteslice(0, dependent.start_offset).count("\n") + 1
    assert_equal pair_line, start_line
    refute_equal 1, start_line

    suppressed = source.sub("dependent: :destroy,", "dependent: :destroy, # mutineer:disable-line macro_option_removal")
    with_source(suppressed) do |path, text|
      config = Mutineer::Config.new(sources: [path], project_root: File.dirname(path), operators: %w[macro_option_removal])
      jobs, ignored, = Mutineer::JobPlan.collect_jobs(config, Mutineer::MutatorRegistry.resolve(%w[macro_option_removal]))
      assert_equal 1, jobs.size
      assert_equal 1, ignored.size
      ignored_text = text.byteslice(ignored.first.mutation.start_offset...ignored.first.mutation.end_offset)
      job_text = text.byteslice(jobs.first[1].start_offset...jobs.first[1].end_offset)
      assert_includes ignored_text, "dependent:"
      assert_includes job_text, "inverse_of:"
    end
  end

  def test_declines_a_validates_with_no_validator_left
    mutations, declined, = mutations_for("class Card\n  validates :name, presence: true\nend\n")
    assert_empty mutations
    assert_equal 1, declined

    mutations, declined, text = mutations_for("class Card\n  validates :name, presence: true, allow_nil: true\nend\n")
    assert_equal 1, mutations.size
    assert_equal 1, declined
    assert_includes mutations.first.apply(text), "presence: true"
    refute_includes mutations.first.apply(text), "allow_nil:"

    mutations, declined, text = mutations_for("class Card\n  validates :name, presence: true, except_on: :create\nend\n")
    assert_equal 1, mutations.size
    assert_equal 1, declined
    assert_includes mutations.first.apply(text), "presence: true"
    assert_includes text.byteslice(mutations.first.start_offset...mutations.first.end_offset), "except_on:"
  end

  def test_validates_with_never_declines
    source = "class Card\n  validates_with FooValidator, if: :x\nend\n"
    mutations, declined, text = mutations_for(source)
    assert_equal 1, mutations.size
    assert_equal 0, declined
    assert_includes mutations.first.apply(text), "validates_with FooValidator, **{}"
    assert mutations.first.valid?(text)
  end

  def test_def_operators_never_edit_a_macro_subject
    source = "class Card\n  has_many :parts, dependent: :destroy\nend\n"
    with_source(source) do |path, text|
      subject = macro_subjects(path).first
      names = Mutineer::MutatorRegistry::ALL.keys - Mutineer::MutatorRegistry::MACRO_NAMES
      names.each do |name|
        operator = Mutineer::MutatorRegistry::ALL.fetch(name).new
        assert_empty operator.mutations_for(subject, text), name
      end
    end
  end
end
