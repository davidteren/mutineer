# frozen_string_literal: true

require_relative "../test_helper"

class BaseTest < Minitest::Test
  # Emits one mutation per `true`, so each test counts what the walk reaches.
  class TrueFinder < Mutineer::Mutators::Base
    def visit_true_node(node)
      @mutations << Mutineer::Mutation.new(start_offset: node.location.start_offset,
                                           end_offset: node.location.end_offset,
                                           replacement: "false", operator: :true_finder)
    end
  end

  def mutations(body)
    source = "def m\n  #{body}\nend\n"
    def_node = Mutineer::Parser.parse_string(source).value.statements.body.first
    subject = Mutineer::Subject.new(file: "snippet.rb", namespace: [], name: :m,
                                    singleton: false, def_node: def_node)
    TrueFinder.new.mutations_for(subject, source)
  end

  def test_nested_def_is_skipped
    assert_empty mutations("def inner\n    true\n  end")
  end

  def test_def_in_class_shift_obj_is_walked
    assert_equal 1, mutations("class << obj\n    def inner\n      true\n    end\n  end").size
  end

  def test_class_shift_self_body_is_walked
    assert_equal 1, mutations("class << self\n    X = true\n  end").size
  end
end
