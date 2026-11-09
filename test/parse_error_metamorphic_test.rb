# frozen_string_literal: true

require_relative "test_helper"

# #392, metamorphic checks of Parser.new_errors?. Example tests in
# parser_test.rb pin known cases; these check the rule across every operator's
# real edits. Each test runs a mutant twice, once on clean source and once on
# source that carries a parse error, and requires the same valid result.
class ParseErrorMetamorphicTest < Minitest::Test
  # Small files, so the test stays fast while every operator meets many shapes
  # of Ruby.
  CORPUS = Dir[File.expand_path("fixtures/*.rb", __dir__)].sort.freeze

  # Methods that are a parse error on every Prism version: a duplicated
  # argument and a constant write in a method body. The last one is an error
  # only on Prism 2 and later (#392); on Prism 1 that case compares clean with
  # clean, which must also agree.
  BROKEN = [
    "def __mutineer_broken(x, x)\nend\n",
    "def __mutineer_broken\n  B = 1 + 2\nend\n",
    "def __mutineer_broken\n  T += 1\nend\n"
  ].freeze

  # Method bodies whose edits fall inside a constant write in a method, a
  # dynamic constant assignment on every Prism. `C` stands for the constant;
  # the clean twin uses the local `c`, which has the same length, so each
  # mutant has the same offsets in both. Covers an error that encloses the
  # edit (`C = 1 + 2` to `C = 1 - 2`) and one the edit wraps (condition
  # negation turns `if C = ...` into `if !(C = ...)`).
  ENCLOSING = [
    "C = 1 + 2 * 3",
    "C = (a > b) && true",
    "C = [a, b].map { |v| v - 1 }",
    "if C = a + 1\n    b\n  end",
    "return 1 unless C = a == b",
    "C = a ? b + 1 : nil",
    "x = C = a - b"
  ].freeze

  # An error the original already has, away from the edit, before or after
  # it, never changes whether a mutant is valid.
  def test_an_existing_error_away_from_the_edit_never_changes_validity
    pairs = 0
    CORPUS.each do |path|
      source = File.read(path)
      next unless Mutineer::Parser.parse_string(source).errors.empty?

      mutations_in(path, source).each do |mutation|
        clean = mutation.valid?(source)
        BROKEN.each do |broken|
          assert_equal clean, mutation.valid?(source + broken), mismatch(source, mutation, "#{broken.lines.first.strip} after #{File.basename(path)}")
          moved = mutation.with(start_offset: mutation.start_offset + broken.bytesize,
                                end_offset: mutation.end_offset + broken.bytesize)
          assert_equal clean, moved.valid?(broken + source), mismatch(source, mutation, "#{broken.lines.first.strip} before #{File.basename(path)}")
          pairs += 2
        end
      end
    end
    assert_operator pairs, :>, 1000, "the corpus must yield enough mutants to mean something"
  end

  # An existing error that encloses or is wrapped by the edit keeps a mutant
  # valid exactly when the same edit is valid on the clean twin.
  def test_an_existing_error_around_the_edit_never_changes_validity
    pairs = 0
    ENCLOSING.each do |body|
      dirty = "def m(a, b)\n  #{body}\nend\n"
      clean = dirty.gsub(/\bC\b/, "c")
      refute_empty Mutineer::Parser.parse_string(dirty).errors, "#{body.inspect} must carry the error"
      assert_empty Mutineer::Parser.parse_string(clean).errors, "#{body.inspect} twin must parse clean"

      mutations = mutations_in("snippet.rb", dirty)
      # A wrapping mutant copies the constant into its replacement; its twin
      # copies the local.
      twins = mutations.map { |m| m.with(replacement: m.replacement.gsub(/\bC\b/, "c")) }
      assert_equal twins, mutations_in("snippet.rb", clean), "#{body.inspect}: both twins must give the same mutants"
      mutations.zip(twins) do |mutation, twin|
        assert_equal twin.valid?(clean), mutation.valid?(dirty), mismatch(dirty, mutation, body.inspect)
        pairs += 1
      end
    end
    assert_operator pairs, :>, 40, "the bodies must yield enough mutants to mean something"
  end

  private

  # Every operator's mutants for each subject of the source.
  #
  # @return [Array<Mutineer::Mutation>]
  def mutations_in(path, source)
    program = Mutineer::Parser.parse_string(source).value
    subjects = path == "snippet.rb" ? [snippet_subject(program)] : Mutineer::Project.discover([path])
    subjects.flat_map do |subject|
      Mutineer::MutatorRegistry::ALL.values.flat_map { |klass| klass.new.mutations_for(subject, source) }
    end
  end

  # The subject for a snippet's single method.
  #
  # @return [Mutineer::Subject]
  def snippet_subject(program)
    def_node = program.statements.body.first
    Mutineer::Subject.new(file: "snippet.rb", namespace: [], name: def_node.name, singleton: false, def_node: def_node)
  end

  # A failure message that names the line, the edit, and where the error is.
  #
  # @return [String]
  def mismatch(source, mutation, context)
    line = source.byteslice(0, mutation.start_offset).count("\n") + 1
    original = source.byteslice(mutation.start_offset...mutation.end_offset)
    "line #{line} [#{mutation.operator}] `#{original}` -> `#{mutation.replacement}` changed validity (#{context})"
  end
end
