# frozen_string_literal: true

require "prism"
require "set"
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
        visitor.promote_module_functions!
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
        @lexical_stack = [] # class/module names as written, `::X` kept (#145)
        @subjects = []
        @singleton_depth = 0
        @module_function_active = false # bareword `module_function` seen in this module body
        @module_function_names = []     # [namespace, name] from `module_function :a` / `module_function def` (#98)
        super()
      end

      # Promote `module_function :name` / `module_function def name` subjects to
      # singleton after the full walk — the naming call may appear before or after
      # the def, so it can't be decided at visit_def_node time (#20). Only methods
      # of the module that made the call are promoted (#98); namespaces compare
      # joined, since `module A::B` and nested `module A; module B` differ as arrays.
      #
      # @return [void]
      def promote_module_functions!
        return if @module_function_names.empty?

        named = @module_function_names.to_set
        @subjects.each { |s| s.singleton = true if named.include?([s.namespace.join("::"), s.name]) }
      end

      # Visits class nodes and tracks namespace nesting.
      #
      # @param node [Prism::ClassNode] class node.
      # @return [void]
      def visit_class_node(node)
        with_namespace(node.constant_path) { super }
      end

      # Visits module nodes and tracks namespace nesting.
      #
      # @param node [Prism::ModuleNode] module node.
      # @return [void]
      def visit_module_node(node)
        with_namespace(node.constant_path) { super }
      end

      # Track `module_function` so its methods are recorded as singletons (#20) —
      # the called form is the singleton method on the module object. Bareword
      # `module_function` flips all SUBSEQUENT defs in this body; the argument
      # forms (`:sym`, `def`) name methods promoted after the walk.
      #
      # @param node [Prism::CallNode] call node.
      # @return [void]
      def visit_call_node(node)
        if %i[public private protected].include?(node.name) && node.receiver.nil? && node.arguments.nil?
          @module_function_active = false # without arguments, Ruby goes back to instance methods
        end
        if node.name == :module_function && node.receiver.nil?
          args = node.arguments&.arguments || []
          if args.empty?
            @module_function_active = true
          else
            namespace = @namespace_stack.join("::")
            args.each do |arg|
              @module_function_names << [namespace, arg.value.to_sym] if arg.is_a?(Prism::SymbolNode)
              @module_function_names << [namespace, arg.name] if arg.is_a?(Prism::DefNode)
            end
          end
        end
        super
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
          lexical: @lexical_stack.dup,
          name: node.name,
          singleton: !node.receiver.nil? || @singleton_depth.positive? || @module_function_active,
          def_node: node
        )
        super
      end

      private

      # Runs the block with `path` pushed as the current namespace. A
      # root-anchored path (`module ::X` / `class ::X`) names the top-level X,
      # not X nested in the enclosing scope, so the namespace restarts there.
      # Bareword `module_function` state does not cross a class or module
      # boundary: each body starts without it, and the outer state returns after.
      #
      # @param path [Prism::Node] the class/module constant path.
      # @yield the class or module body visit.
      # @return [void]
      def with_namespace(path)
        saved_stack = @namespace_stack
        saved_lexical = @lexical_stack
        saved_active = @module_function_active
        name = extract_constant_name(path)
        root = root_anchored?(path)
        @namespace_stack = root ? [name] : saved_stack + [name]
        @lexical_stack = saved_lexical + [root ? "::#{name}" : name]
        @module_function_active = false
        yield
      ensure
        @namespace_stack = saved_stack
        @lexical_stack = saved_lexical
        @module_function_active = saved_active
      end

      # True when a constant path starts with `::` (e.g. `::X` or `::A::B`).
      #
      # @param node [Prism::Node] constant path node.
      # @return [Boolean]
      def root_anchored?(node)
        node = node.parent while node.is_a?(Prism::ConstantPathNode) && node.parent
        node.is_a?(Prism::ConstantPathNode)
      end

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
