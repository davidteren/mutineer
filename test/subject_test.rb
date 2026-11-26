# frozen_string_literal: true

require_relative "test_helper"

class SubjectTest < Minitest::Test
  def def_node(source)
    Mutineer::Parser.parse_string(source).value.statements.body.first
  end

  def test_qualified_name_instance_method
    s = Mutineer::Subject.new(file: "f.rb", namespace: %w[Billing Invoice],
                            name: :total, singleton: false, def_node: def_node("def total; end"))
    assert_equal "Billing::Invoice#total", s.qualified_name
  end

  def test_qualified_name_singleton_method
    s = Mutineer::Subject.new(file: "f.rb", namespace: %w[Billing Invoice],
                            name: :build, singleton: true, def_node: def_node("def self.build; end"))
    assert_equal "Billing::Invoice.build", s.qualified_name
  end

  def test_qualified_name_top_level
    s = Mutineer::Subject.new(file: "f.rb", namespace: [],
                            name: :helper, singleton: false, def_node: def_node("def helper; end"))
    assert_equal "#helper", s.qualified_name
  end

  # #256: redefine needs a named owner; reload reaches everything but a
  # concern's `included` or `prepended` block.
  def test_unplaceable_depends_on_the_strategy
    build = lambda do |**flags|
      Mutineer::Subject.new(file: "f.rb", namespace: ["Billing"], name: :tag, singleton: false,
                            def_node: def_node("def tag; end"), **flags)
    end
    hook = build.call(owner_unknown: true, hook_block: true)
    assert hook.unplaceable?("redefine")
    assert hook.unplaceable?("reload")

    named_in_hook = build.call(owner_unknown: false, hook_block: true)
    refute named_in_hook.unplaceable?("redefine")
    assert named_in_hook.unplaceable?("reload")

    anonymous = build.call(owner_unknown: true, hook_block: false)
    assert anonymous.unplaceable?("redefine")
    refute anonymous.unplaceable?("reload")

    plain = build.call
    refute plain.unplaceable?("redefine")
    refute plain.unplaceable?("reload")

    # #297: reload places a hook-block def that discovery found a hook call for.
    placed = build.call(owner_unknown: true, hook_block: true, reload_hook_call: Object.new)
    assert placed.unplaceable?("redefine")
    refute placed.unplaceable?("reload")
  end

  def test_body_loc_nil_for_empty_method
    s = Mutineer::Subject.new(file: "f.rb", namespace: [],
                            name: :empty, singleton: false, def_node: def_node("def empty; end"))
    assert_nil s.body_loc
  end
end
