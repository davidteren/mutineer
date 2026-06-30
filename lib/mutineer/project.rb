# frozen_string_literal: true

require "prism"
require_relative "parser"
require_relative "subject"

module Mutineer
  # Subject discovery: parse each path and walk its AST for method definitions,
  # tracking the enclosing class/module namespace.
  class Project
    # Discovers subjects from source paths.
    #
    # @param paths [Array<String>] source file paths.
    # @param only [String, nil] optional qualified-name filter.
    # @return [Array<Mutineer::Subject>] discovered subjects.
    def self.discover(paths, only: nil)
      subjects = Array(paths).flat_map do |path|
        result = Parser.parse_file(path)
        visitor = SubjectVisitor.new(path)
        visitor.visit(result.value)
        visitor.subjects
      end
      only ? subjects.select { |s| s.qualified_name == only } : subjects
    end

    # Walks an AST, maintaining a namespace stack, emitting Subjects.
    # Nested inside Project to signal its private role.
    class SubjectVisitor < Prism::Visitor
      attr_reader :subjects

      # Builds a subject visitor.
      #
      # @param file [String] source file path being visited.
      def initialize(file)
        @file = file
        @namespace_stack = []
        @subjects = []
        @singleton_depth = 0
        super()
      end

      # Visits class nodes and tracks namespace nesting.
      #
      # @param node [Prism::ClassNode] class node.
      # @return [void]
      def visit_class_node(node)
        @namespace_stack.push(extract_constant_name(node.constant_path))
        super
        @namespace_stack.pop
      end

      # Visits module nodes and tracks namespace nesting.
      #
      # @param node [Prism::ModuleNode] module node.
      # @return [void]
      def visit_module_node(node)
        @namespace_stack.push(extract_constant_name(node.constant_path))
        super
        @namespace_stack.pop
      end

      # Methods inside `class << self` are class methods of the enclosing
      # namespace, but their def nodes have no receiver — track the singleton
      # context so they're recorded as singleton (so redefine targets the
      # singleton_class, not instances). `class << some_other_obj` can't be
      # represented against the namespace, so its defs are skipped (not recursed).
      #
      # @param node [Prism::SingletonClassNode] singleton-class node.
      # @return [void]
      def visit_singleton_class_node(node)
        return unless node.expression.is_a?(Prism::SelfNode)

        @singleton_depth += 1
        super
        @singleton_depth -= 1
      end

      # Records a discovered method definition.
      #
      # @param node [Prism::DefNode] method definition node.
      # @return [void]
      def visit_def_node(node)
        @subjects << Subject.new(
          file: @file,
          namespace: @namespace_stack.dup,
          name: node.name,
          singleton: !node.receiver.nil? || @singleton_depth.positive?,
          def_node: node
        )
        super
      end

      private

      # Extracts a constant name from a Prism constant node.
      #
      # @api private
      # @param node [Prism::Node] constant node.
      # @return [String, nil] constant name.
      def extract_constant_name(node)
        case node
        when Prism::ConstantReadNode
          node.name.to_s
        when Prism::ConstantPathNode
          [extract_constant_name(node.parent), node.name.to_s].compact.join("::")
        end
      end
    end
  end
end
