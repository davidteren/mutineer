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
      # Calls whose block is the body of the class they build: receiver name => method.
      CLASS_BUILDERS = { "Data" => :define, "Struct" => :new, "Class" => :new, "Module" => :new }.freeze

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
        @block_owner = nil
        @block_namespace = nil
        @owner_unknown = false
        @assigned = nil
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
      # forms (`:sym`, `def`) name methods promoted after the walk. A builder
      # block's defs belong to the class it builds; one not assigned to a
      # constant has no name, so its subjects are marked `owner_unknown`.
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
        return super unless builds_class?(node)

        owner = @assigned&.first.equal?(node) ? @assigned.last : [nil, @namespace_stack, true]
        with_block_owner(owner) { super }
      end

      # Names the class a builder block assigned to this constant builds (see {#builds_class?}).
      #
      # `=`, `||=` and `&&=` store the class, so each names it; `+=` stores what `+`
      # returns, so its builder is left unnamed.
      #
      # @param node [Prism::ConstantWriteNode, Prism::ConstantPathWriteNode, Prism::ConstantOrWriteNode,
      #   Prism::ConstantAndWriteNode, Prism::ConstantPathOrWriteNode, Prism::ConstantPathAndWriteNode]
      #   constant assignment.
      # @return [void]
      def visit_constant_write_node(node)
        call = assigned_value(node.value)
        return super unless builds_class?(call)

        saved = @assigned
        @assigned = [call, assigned_owner(node)]
        begin
          super
        ensure
          @assigned = saved
        end
      end
      alias visit_constant_path_write_node visit_constant_write_node
      alias visit_constant_or_write_node visit_constant_write_node
      alias visit_constant_and_write_node visit_constant_write_node
      alias visit_constant_path_or_write_node visit_constant_write_node
      alias visit_constant_path_and_write_node visit_constant_write_node

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
        saved_active = @module_function_active
        super
        @module_function_active = saved_active # a visibility call in here is not the module body's
        @singleton_depth -= 1
      end

      # Records a discovered method definition.
      #
      # @param node [Prism::DefNode] method definition node.
      # @return [void]
      def visit_def_node(node)
        @subjects << Subject.new(
          file: @file,
          namespace: (@block_namespace || @namespace_stack).dup,
          lexical: @lexical_stack.dup,
          block_owner: @block_owner,
          owner_unknown: @owner_unknown,
          name: node.name,
          singleton: !node.receiver.nil? || @singleton_depth.positive? || @module_function_active,
          def_node: node
        )
        saved_active = @module_function_active
        super
        @module_function_active = saved_active # a visibility call in a method body runs only when it is called
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
        saved_block = [@block_owner, @block_namespace, @owner_unknown]
        name = extract_constant_name(path)
        root = root_anchored?(path)
        @namespace_stack = root ? [name] : saved_stack + [name]
        @lexical_stack = saved_lexical + [root ? "::#{name}" : name]
        @module_function_active = false
        @block_owner = @block_namespace = nil
        @owner_unknown = false
        yield
      ensure
        @namespace_stack = saved_stack
        @lexical_stack = saved_lexical
        @module_function_active = saved_active
        @block_owner, @block_namespace, @owner_unknown = saved_block
      end

      # Resolves the constant an assignment writes the way Ruby does. `X` is in the
      # current namespace, `::X` and a path at the top level start from Object, and
      # `self::X` is under the current class (the built class inside a builder
      # block). Any other path is looked up at run time, so its owner is unknown
      # and the subject is named as written.
      #
      # @param node [Prism::Node] constant assignment.
      # @return [Array(String, Array<String>, Boolean)] owner, namespace, unknown.
      def assigned_owner(node)
        return named_owner(@namespace_stack + [node.name.to_s]) unless node.respond_to?(:target)

        names = []
        path = node.target
        while path.is_a?(Prism::ConstantPathNode)
          names.unshift(path.name.to_s)
          path = path.parent
        end
        base =
          case path
          when nil then []
          when Prism::SelfNode then @block_namespace || @namespace_stack unless @owner_unknown
          when Prism::ConstantReadNode then [path.name.to_s] if @namespace_stack.empty?
          end
        base ? named_owner(base + names) : [nil, [node.target.slice], true]
      end

      # The owner for a resolved namespace, root-anchored so the redefine
      # wrapper loads onto that constant from any nesting.
      #
      # @param namespace [Array<String>] resolved namespace.
      # @return [Array(String, Array<String>, Boolean)]
      def named_owner(namespace)
        ["::#{namespace.join("::")}", namespace, false]
      end

      # The value an assignment stores: the last statement inside parentheses or a
      # `begin` without `rescue`, which Ruby returns from them.
      #
      # @param node [Prism::Node] assigned expression.
      # @return [Prism::Node, nil]
      def assigned_value(node)
        loop do
          body =
            case node
            when Prism::ParenthesesNode then node.body
            when Prism::BeginNode then node.statements unless node.rescue_clause
            end
          return node unless body

          node = body.is_a?(Prism::StatementsNode) ? body.body.last : body
        end
      end

      # True when the node is `Data.define`, `Struct.new`, `Class.new` or `Module.new` with a block.
      #
      # @param node [Prism::Node, nil] node.
      # @return [Boolean]
      def builds_class?(node)
        node.is_a?(Prism::CallNode) && node.block.is_a?(Prism::BlockNode) &&
          CLASS_BUILDERS[node.receiver&.slice&.delete_prefix("::")] == node.name
      end

      # Runs the block with the defs it visits owned by the class a builder block builds.
      #
      # @param owner [Array(String, Array<String>, Boolean)] the owner as written, its namespace,
      #   and whether that name is unknown.
      # @yield the builder call visit.
      # @return [void]
      def with_block_owner(owner)
        saved = [@block_owner, @block_namespace, @owner_unknown, @module_function_active]
        @block_owner, @block_namespace, @owner_unknown = owner
        @module_function_active = false
        yield
      ensure
        @block_owner, @block_namespace, @owner_unknown, @module_function_active = saved
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
