# frozen_string_literal: true

require_relative "../test_helper"

class ChainLinkTest < Minitest::Test
  def subject_for(source)
    def_node = Mutineer::Parser.parse_string(source).value.statements.body.first
    Mutineer::Subject.new(file: "snippet.rb", namespace: [], name: def_node.name,
                        singleton: false, def_node: def_node)
  end

  def run_mutator(body)
    source = "def m\n  #{body}\nend\n"
    [Mutineer::Mutators::ChainLink.new.mutations_for(subject_for(source), source), source]
  end

  # Each mutation as the source it removes, in emission order.
  def dropped(body)
    mutations, source = run_mutator(body)
    mutations.each do |m|
      assert_equal "", m.replacement
      assert_equal :chain_link, m.operator
      assert m.valid?(source), "mutated #{body.inspect} should re-parse"
    end
    mutations.map { |m| source[m.start_offset...m.end_offset] }
  end

  def test_drops_each_link_but_keeps_receiver_and_final_call
    assert_equal [".owner", ".account"], dropped("user.account.owner.name")
  end

  def test_single_call_and_bare_calls_yield_none
    assert_empty dropped("user.name")
    assert_empty dropped("name")
    assert_empty dropped("a + b")
  end

  def test_link_takes_its_arguments_and_block
    assert_equal [".where(active: true)"], dropped("users.where(active: true).count")
    assert_equal [".select { |u| u.ok? }"], dropped("users.select { |u| u.ok? }.first")
  end

  def test_multiline_chain_drops_the_line_break_with_the_link
    body = "users\n    .where(active: true)\n    .order(:name)\n    .first"
    mutations, source = run_mutator(body)
    assert_equal ["\n    .order(:name)", "\n    .where(active: true)"],
                 mutations.map { |m| source[m.start_offset...m.end_offset] }
    assert_equal "def m\n  users\n    .where(active: true)\n    .first\nend\n", mutations.first.apply(source)
  end

  def test_safe_navigation_and_double_colon_links
    assert_equal ["&.account"], dropped("user&.account&.name")
    assert_equal ["::account"], dropped("user::account.name")
  end

  def test_chain_begins_at_a_receiver_that_is_not_a_dotted_call
    assert_empty dropped("params[:user].name")
    assert_equal [".c"], dropped("a.b[0].c.d")
  end

  def test_calls_in_arguments_and_blocks_start_their_own_chains
    assert_equal [".b", ".y"], dropped("a.b.c(x.y.z)")
    assert_equal [".b", ".y"], dropped("a.b.each { |x| x.y.z }")
  end

  def test_skipped_links_are_kept
    %w[to_s to_a to_h dup clone freeze itself new].each do |name|
      assert_empty dropped("value.#{name}.strip"), "#{name} should not be dropped"
    end
    assert_equal [".strip"], dropped("value.to_s.strip.downcase")
  end

  def test_compound_writes_and_targets_treat_their_receiver_as_links
    ["user.account.visits += 1", "user.account.name ||= 1", "user.account.name &&= 1",
     "user.account.name, other = 1, 2", "for user.account.name in names; end"].each do |body|
      assert_equal [".account"], dropped(body), "for #{body.inspect}"
    end
  end

  def test_repeated_links_get_distinct_ids
    source = "def m\n  a.b.c\n  a.b.d\nend\n"
    subject = subject_for(source)
    mutations = Mutineer::Mutators::ChainLink.new.mutations_for(subject, source)
    ids = Mutineer::MutantId.for_subject(subject, source, mutations, path: "snippet.rb")
    assert_equal 2, ids.uniq.size
  end

  def test_nested_def_is_its_own_subject
    assert_empty dropped("def inner = a.b.c")
  end
end
