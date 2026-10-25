# frozen_string_literal: true

require_relative "../test_helper"

class CallToReceiverTest < Minitest::Test
  def subject_for(source)
    def_node = Mutineer::Parser.parse_string(source).value.statements.body.first
    Mutineer::Subject.new(file: "snippet.rb", namespace: [], name: def_node.name,
                        singleton: false, def_node: def_node)
  end

  def run_mutator(body, klass = Mutineer::Mutators::CallToReceiver)
    source = "def m\n  #{body}\nend\n"
    [klass.new.mutations_for(subject_for(source), source), source]
  end

  # Each mutated body, in emission order.
  def mutated(body)
    mutations, source = run_mutator(body)
    mutations.map do |m|
      assert_equal :call_to_receiver, m.operator
      assert m.valid?(source), "mutated #{body.inspect} should re-parse"
      m.apply(source).delete_prefix("def m\n  ").delete_suffix("\nend\n")
    end
  end

  def test_replaces_only_the_last_call_of_a_chain
    assert_equal ["a.b"], mutated("a.b.c")
    assert_equal ["a.b.c"], mutated("a.b.c.d")
  end

  def test_safe_navigation_and_double_colon
    assert_equal ["a"], mutated("a&.b")
    assert_equal ["a"], mutated("a::b")
    assert_equal ["foo.bar"], mutated("foo.bar&.baz")
    assert_equal ["Foo::Bar"], mutated("Foo::Bar.baz")
  end

  def test_receiver_that_is_not_a_call
    assert_equal ["self"], mutated("self.foo")
    assert_equal ["x"], mutated("x.()")
    assert_equal ["(a + b)"], mutated("(a + b).abs")
  end

  def test_call_names_with_a_suffix
    assert_equal ["a"], mutated("a.bar!")
    assert_equal ["a"], mutated("a.b?")
  end

  def test_drops_the_arguments_and_the_block
    assert_equal ["foo"], mutated("foo.bar baz")
    assert_equal ["a"], mutated("a.b(&:c)")
    assert_equal ["a"], mutated("a.b do |x| x end")
  end

  def test_calls_in_arguments_and_blocks_start_their_own_chains
    assert_equal ["x", "x.map { |y| y }"], mutated("x.map { |y| y.z }")
    assert_equal ["a", "a.b(c)"], mutated("a.b(c.d)")
  end

  def test_receiver_of_a_call_that_is_not_dotted_is_the_last_call_of_its_chain
    assert_equal ["a[0]"], mutated("a.b[0]")
    assert_equal ["a + 1"], mutated("a.b + 1")
  end

  def test_call_inside_other_expressions
    assert_equal ["!x"], mutated("!x.empty?")
    assert_equal ["-x"], mutated("-x.abs")
    assert_equal ['"#{a}"'], mutated('"#{a.b}"')
    assert_equal ["defined?(a)"], mutated("defined?(a.b)")
    assert_equal ["a ? 1 : 2"], mutated("a.b ? 1 : 2")
    assert_equal ["a rescue nil"], mutated("a.b rescue nil")
    assert_equal ["return a"], mutated("return a.b")
  end

  def test_multiline_chain
    assert_equal ["a\n    .b"], mutated("a\n    .b\n    .c")
  end

  def test_bare_calls_and_operator_calls_yield_none
    assert_empty mutated("name")
    assert_empty mutated("a + b")
    assert_empty mutated("a[0]")
  end

  def test_setters_yield_none
    assert_empty mutated("x.a.b = 1")
    assert_empty mutated("foo&.bar = 1")
  end

  def test_compound_writes_and_targets_treat_their_receiver_as_links
    ["a.b.c += 1", "a.b.c ||= 1", "a.b.c &&= 1", "a.b.c, d = 1, 2", "for a.b.c in list; end"].each do |body|
      assert_empty mutated(body), "for #{body.inspect}"
    end
  end

  def test_skipped_names_yield_none
    %w[x.dup x.clone Foo.new x.freeze x.itself x.to_set].each do |body|
      assert_empty mutated(body), "for #{body.inspect}"
    end
    assert_equal ["x.to_s"], mutated("x.to_s.strip")
  end

  def test_conversions_on_the_last_call_are_replaced
    conversions = %i[to_s to_str to_sym to_i to_int to_f to_r to_c to_a to_ary to_h to_hash to_proc]
    # The two lists differ by exactly these names, and chain_link keeps them all.
    assert_equal conversions, Mutineer::Mutators::ChainLink::SKIPPED - Mutineer::Mutators::CallToReceiver::SKIPPED
    assert_empty Mutineer::Mutators::CallToReceiver::SKIPPED - Mutineer::Mutators::ChainLink::SKIPPED
    conversions.each do |name|
      assert_equal ["x"], mutated("x.#{name}"), "for x.#{name}"
    end
    assert_equal ["m[1]"], mutated("m[1].to_i")
    assert_equal ["a.b"], mutated("a.b.to_s")
    # A known equivalent (interpolation calls to_s anyway). Skips are by name only.
    assert_equal ['"#{a}"'], mutated('"#{a.to_s}"')
  end

  def test_nested_def_is_its_own_subject
    assert_empty mutated("def inner = a.b")
  end

  def test_heredoc_body_stays_after_the_replacement
    source = "def m\n  <<~X.strip\n    hi\n  X\nend\n"
    mutations = Mutineer::Mutators::CallToReceiver.new.mutations_for(subject_for(source), source)
    assert_equal 1, mutations.size
    assert_equal "def m\n  <<~X\n    hi\n  X\nend\n", mutations.first.apply(source)
    assert mutations.first.valid?(source)
  end

  def test_repeated_calls_get_distinct_ids
    source = "def m\n  a.b\n  a.b\nend\n"
    subject = subject_for(source)
    mutations = Mutineer::Mutators::CallToReceiver.new.mutations_for(subject, source)
    ids = Mutineer::MutantId.for_subject(subject, source, mutations, path: "snippet.rb")
    assert_equal 2, ids.uniq.size
  end

  def test_never_gives_the_same_source_as_chain_link
    ["a.b.c", "a.b.c.d", "a&.b&.c", "a.b(c.d).e", "a\n    .b\n    .c", "a.b[0].c.d",
     "x.map { |y| y.z.w }", "a.b.c += 1", "a.b + c.d.e", "a.b.to_s", "a.to_s.to_i"].each do |body|
      ours, source = run_mutator(body)
      theirs, = run_mutator(body, Mutineer::Mutators::ChainLink)
      common = ours.map { |m| m.apply(source) } & theirs.map { |m| m.apply(source) }
      assert_empty common, "for #{body.inspect}"
    end
  end

  def test_a_repeated_last_call_gives_the_same_source_as_chain_link
    ours, source = run_mutator("node.name.name")
    theirs, = run_mutator("node.name.name", Mutineer::Mutators::ChainLink)
    assert_equal ours.map { |m| m.apply(source) }, theirs.map { |m| m.apply(source) }
  end

  def test_calls_inside_compound_writes_and_targets_are_visited
    assert_equal ["a.b.c += x"], mutated("a.b.c += x.y")
    assert_equal ["a.b(c).e ||= 1"], mutated("a.b(c.d).e ||= 1")
    assert_equal ["a.b.c &&= x"], mutated("a.b.c &&= x.y")
    assert_equal ["a.b(c).e, f = 1, 2"], mutated("a.b(c.d).e, f = 1, 2")
  end

  def test_explicit_operator_calls_yield_none
    assert_empty mutated("a.+(1)")
    assert_empty mutated("x.[](0)")
  end

  def test_name_that_starts_with_a_non_ascii_letter
    assert_equal ["a"], mutated("a.ñandu")
  end

  def test_heredoc_body_inside_the_replaced_call_yields_none
    ["x = <<~X\n    l\n  X\n    .strip",
     "foo(<<~X).bar do\n    l\n  X\n  end"].each do |body|
      assert_empty mutated(body), "for #{body.inspect}"
    end
    mutations, source = run_mutator("rows = execute(<<~SQL).map do |row|\n    SELECT 1\n  SQL\n    row.first\n  end")
    assert_equal 1, mutations.size
    assert_equal "row.first", source[mutations.first.start_offset...mutations.first.end_offset]
  end

  # The declined count after one run on `body`.
  def declined(body)
    source = "def m\n  #{body}\nend\n"
    Mutineer::Mutators::CallToReceiver.new.tap { |op| op.mutations_for(subject_for(source), source) }.declined
  end

  def test_skipped_name_counts_as_declined
    %w[x.to_s x.dup Foo.new x.freeze x.itself x.to_a].each do |body|
      assert_equal 1, declined(body), "for #{body.inspect}"
    end
    ["a.+(1)", "a.b = 1", "x.to_s.strip"].each do |body|
      assert_equal 0, declined(body), "for #{body.inspect}"
    end
  end
end
