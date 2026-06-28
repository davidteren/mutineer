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

  def test_body_loc_nil_for_empty_method
    s = Mutineer::Subject.new(file: "f.rb", namespace: [],
                            name: :empty, singleton: false, def_node: def_node("def empty; end"))
    assert_nil s.body_loc
  end
end
