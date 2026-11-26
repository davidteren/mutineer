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
        visitor = SubjectVisitor.new(path, plain_path_calls(result.value), unkept_constant_names(result.value))
        visitor.visit(result.value)
        visitor.promote_module_functions!
        exclude_ambiguous_hook_defs!(visitor.subjects, result.value)
        mark_callback_definers!(visitor.subjects, result.value)
        visitor.subjects
      end
      only ? subjects.select { |s| s.qualified_name == only } : subjects
    end

    # The last names of the constants the file writes more than once, with
    # any kind of write ({CONSTANT_WRITES} or a multiple-assignment target).
    # Reload does not keep such a constant (#528): a kept first write would get
    # the value of the last write, which changes what a line between the two
    # sees. Part of {unkept_constant_names}.
    #
    # @param program [Prism::ProgramNode] the parsed file.
    # @return [Set<Symbol>]
    def self.repeated_constant_names(program)
      counts = Hash.new(0)
      nodes = [program]
      while (node = nodes.pop)
        nodes.concat(node.compact_child_nodes)
        next if node.is_a?(Prism::ClassNode) || node.is_a?(Prism::ModuleNode)

        name = defined_constant_name(node)
        counts[name] += 1 if name
      end
      counts.select { |_name, count| count > 1 }.keys.to_set
    end

    # The last names of the constants reload must not keep (#528): the names
    # the file writes more than once ({repeated_constant_names}), and the
    # names it can change again ({reshaped_constant_names}). Discovery
    # ({SubjectVisitor}), {rebuilt_names} and the reload text
    # ({JobPlan.keep_live_superclasses}) all read this Set from the original
    # text, so a mutant cannot change which constants are kept.
    #
    # @param program [Prism::ProgramNode] the parsed file.
    # @return [Set<Symbol>]
    def self.unkept_constant_names(program)
      repeated_constant_names(program) | reshaped_constant_names(program)
    end

    # The calls on a constant that leave its class as it is, so a file may
    # make them and still have the constant kept.
    RESHAPE_SAFE_CALLS = %i[new []].freeze

    # The calls that can wrap or reopen a class reached without its name
    # (`ORIGIN.class.class_eval { alias_method ... }`). A file that makes one
    # with a receiver keeps none of its constants ({reshaped_constant_names}).
    # `include` and `prepend` are left out: they are common on a hook's
    # `base`, and would drop 77 more of 1,257 corpus constants (#585).
    INDIRECT_RESHAPE_CALLS = %i[alias_method class_eval class_exec module_eval module_exec instance_eval
                                instance_exec define_method const_get].freeze

    # The last names of the constants that the file may change in a way that
    # is not safe to run again on a kept class (#528). It fails closed: a
    # constant is in the Set when the file names it anywhere other than as
    # the receiver of a {RESHAPE_SAFE_CALLS} call (`X.new`), the parent of a
    # path (`X::ORIGIN`), the target of a path write, an argument of a class builder (`Class.new(X)`), a
    # superclass (`class Row < X`), or a `class X`, `module X` or `class << X`
    # statement whose body passes {rerunnable_body?}. So `X.freeze`,
    # `X.class_eval`, `Alias = X` and `[X].each` count, also inside a def,
    # which the file may call at load, as does such a statement with
    # `alias_method :raw_x, :x`, which would wrap the wrapper of the first load
    # so that `x` calls itself. Such a statement on a path (`class X::Q`) counts
    # each name of the path. Names match by their last part. A file that makes
    # an {INDIRECT_RESHAPE_CALLS} call with a receiver counts every constant it
    # writes, as does a file with `eval` or with a `class << expr` statement
    # whose body is unsafe. Such a constant is built again on each load, as
    # before #528. A change made in another file, or through a call outside
    # that list (`include`, `prepend`, `extend`, `method(:alias_method).call`),
    # is not seen (#585).
    #
    # @param program [Prism::ProgramNode] the parsed file.
    # @return [Set<Symbol>]
    def self.reshaped_constant_names(program)
      names = Set.new
      written = Set.new
      indirect = false
      allowed = Set.new.compare_by_identity
      nodes = [program]
      while (node = nodes.pop)
        nodes.concat(node.compact_child_nodes)
        written << defined_constant_name(node) if defined_constant_name(node)
        case node
        when Prism::ClassNode, Prism::ModuleNode
          allowed << node.constant_path
          allowed << node.superclass if node.is_a?(Prism::ClassNode)
          path_names(node.constant_path).each { |name| names << name } unless rerunnable_body?(node.body)
        when Prism::SingletonClassNode
          allowed << node.expression
          unless rerunnable_body?(node.body) || node.expression.is_a?(Prism::SelfNode)
            # `class << ORIGIN.class` reaches a class without its name.
            constant_reference?(node.expression) ? names.merge(path_names(node.expression)) : indirect = true
          end
        when Prism::ConstantPathNode
          allowed << node.parent
        when Prism::ConstantPathWriteNode
          allowed << node.target # a path node, not a read
        when Prism::CallNode
          allowed << node.receiver if RESHAPE_SAFE_CALLS.include?(node.name)
          allowed.merge(node.arguments.arguments) if builder_call?(node) && node.arguments
          if node.receiver
            sent = sent_name(node)
            indirect = true if sent.nil? || INDIRECT_RESHAPE_CALLS.include?(sent)
          end
          indirect = true if node.name == :eval # its string may name any class
        end
        names << node.name if constant_reference?(node) && !allowed.include?(node)
      end
      indirect ? names | written : names
    end

    # The calls that run a method named by their first argument.
    SEND_CALLS = %i[send public_send __send__].freeze

    # The method a call runs: its own name, or the literal symbol or string
    # it passes to `send`, `public_send` or `__send__`
    # (`k.send(:alias_method, ...)`). A computed name, or a `send` of a
    # `send`, gives nil, which may be any method, so the caller fails closed.
    #
    # @param call [Prism::CallNode]
    # @return [Symbol, nil]
    def self.sent_name(call)
      return call.name unless SEND_CALLS.include?(call.name)

      first = call.arguments&.arguments&.first
      return nil unless first.is_a?(Prism::SymbolNode) || first.is_a?(Prism::StringNode)

      name = first.unescaped.to_sym
      SEND_CALLS.include?(name) ? nil : name
    end


    # @param path [Prism::Node] a class or module statement's constant path.
    # @return [Array<Symbol>] each constant name on it (`A::B` gives `A` and `B`).
    def self.path_names(path)
      names = []
      while constant_reference?(path)
        names << path.name
        path = path.is_a?(Prism::ConstantPathNode) ? path.parent : nil
      end
      names
    end

    # @param node [Prism::Node, nil]
    # @return [Boolean] whether `node` reads a constant (`X` or `A::X`).
    def self.constant_reference?(node)
      node.is_a?(Prism::ConstantReadNode) || node.is_a?(Prism::ConstantPathNode)
    end

    # Whether `node` is one pair of parentheses around one statement. Discovery
    # ({guarded_definition?}) and the reload text ({JobPlan.kept_target}) look
    # through such parentheses with this one test.
    #
    # @param node [Prism::Node, nil]
    # @return [Boolean]
    def self.sole_statement_parentheses?(node)
      node.is_a?(Prism::ParenthesesNode) && node.body.is_a?(Prism::StatementsNode) && node.body.body.size == 1
    end

    # Whether reload keeps the class of this constant write (#503, #528). It
    # fails closed: a write it does not keep keeps its text, and the file
    # builds the class again on each load (#575). All three must hold:
    #
    # - The write is a plain `=` of a bare name (`Point = ...`) or of a path
    #   (`Billing::Point = ...`) whose parent is absent (`::Point`), a constant
    #   path or `self`, so the scope the guard reads runs no code a second time.
    # - The name is not in `unkept` ({unkept_constant_names}): the file writes
    #   it only once (a kept first write would get the value of the last one),
    #   and changes it at load only in ways that are safe to run again.
    # - The value is a {kept_builder?} call, which reads nothing the file can
    #   build again. A builder method of the file (`Point = build_point`) would
    #   keep a class its mutant never reaches, a silent false survivor.
    #
    # No class statement has to name the constant: a subclass, an instance or a
    # constant in another file keeps the class too. {JobPlan.kept_constant_splice}
    # and discovery both ask here and {reopened_write?}, so discovery marks
    # every def in a kept value that does not run again {Subject#not_reloaded}.
    #
    # @param node [Prism::Node]
    # @param unkept [Set<Symbol>] {unkept_constant_names} of the file.
    # @return [Boolean]
    def self.kept_constant_write?(node, unkept)
      if node.is_a?(Prism::ConstantWriteNode)
        return false if unkept.include?(node.name)
      elsif node.is_a?(Prism::ConstantPathWriteNode)
        return false if unkept.include?(node.target.name) || !constant_scope?(node.target.parent)
      else
        return false
      end
      kept_builder?(node.value)
    end

    # Whether reload keeps this constant's class and runs its builder block
    # again on it (#528): a {kept_constant_write?} whose value has a block that
    # {rerunnable_block?} accepts. Discovery and {JobPlan.kept_constant_splice}
    # both ask here.
    #
    # @param node [Prism::Node]
    # @param unkept [Set<Symbol>] {unkept_constant_names} of the file.
    # @return [Boolean]
    def self.reopened_write?(node, unkept)
      kept_constant_write?(node, unkept) && !node.value.block.nil? && rerunnable_block?(node.value.block)
    end

    # The calls a builder block may make, beside its defs, and still run again
    # on the class it built: each sets the same thing on a second run.
    RERUN_SAFE_CALLS = %i[attr_reader attr_writer attr_accessor private public protected
                          private_class_method public_class_method].freeze

    # Whether a builder block can run a second time on the class it built and
    # give the same class (#528). It has no parameter of any kind (`|k|`, `_1`
    # or `it` would be the class, and `k.instance_method(:x)` reads its earlier
    # state), and its body passes {rerunnable_body?}.
    #
    # @param block [Prism::BlockNode]
    # @return [Boolean]
    def self.rerunnable_block?(block)
      block.parameters.nil? && rerunnable_body?(block.body)
    end

    # Whether each statement of a builder block's body is safe to run again on
    # the same class: a def; a {RERUN_SAFE_CALLS} call with no receiver, no
    # block, and def or literal arguments; a constant write whose value is a
    # {kept_builder?} or is {class_state_free?}; or a `class`, `module` or
    # `class << self` statement whose own body passes the same test. Anything
    # else can read the earlier state of the class (`alias_method`, `include`,
    # whose `included` hook Ruby runs again, `ORIG = instance_method(:x)`), so
    # it makes the answer false, as does a body with `rescue` or `ensure`.
    #
    # @param body [Prism::Node, nil]
    # @return [Boolean]
    def self.rerunnable_body?(body)
      return true if body.nil?
      return false unless body.is_a?(Prism::StatementsNode)

      body.body.all? do |statement|
        case statement
        when Prism::DefNode then true
        when Prism::ClassNode, Prism::ModuleNode, Prism::SingletonClassNode then rerunnable_body?(statement.body)
        when Prism::ConstantWriteNode, Prism::ConstantPathWriteNode
          kept_builder?(statement.value) || class_state_free?(statement.value)
        when Prism::CallNode
          statement.receiver.nil? && statement.block.nil? && RERUN_SAFE_CALLS.include?(statement.name) &&
            (statement.arguments&.arguments || []).all? do |argument|
              argument.is_a?(Prism::DefNode) || literal_argument?(argument)
            end
        else false
        end
      end
    end

    # Whether a value reads nothing of the class a builder block runs on: it
    # has no `self`, no call without a receiver, and no instance or class
    # variable, outside a def. So `KEYS = OPTIONS.map(&:key).freeze` is free,
    # and `ZERO = new(0)` and `REGISTRY = (@registry = [])` are not: a second
    # run would reset state that other files filled.
    #
    # @param node [Prism::Node]
    # @return [Boolean]
    def self.class_state_free?(node)
      return true if node.is_a?(Prism::DefNode)
      return false if node.is_a?(Prism::SelfNode) || (node.is_a?(Prism::CallNode) && node.receiver.nil?)
      return false if node.class.name.match?(/\APrism::(Instance|Class)Variable/)

      node.compact_child_nodes.all? { |child| class_state_free?(child) }
    end

    # The class builders a kept value may call, by receiver name.
    KEPT_BUILDERS = { Struct: :new, Data: :define, Class: :new }.freeze

    # A `Struct.new`, `Data.define` or `Class.new` call (also `::Struct`) whose
    # arguments are literals: symbols, strings, numbers, `true`, `false`,
    # `nil`, and keyword pairs of those. It may have a literal block. A
    # constant, a variable, a splat or a call in an argument can name a class
    # or value the file builds again, so such a value is not kept (#533).
    #
    # @param node [Prism::Node]
    # @return [Boolean]
    def self.kept_builder?(node)
      return false unless builder_call?(node)
      return false unless node.block.nil? || node.block.is_a?(Prism::BlockNode)

      (node.arguments&.arguments || []).all? { |argument| literal_argument?(argument) }
    end

    # Whether `node` calls `Struct.new`, `Data.define` or `Class.new` (also
    # `::Struct.new`), with any arguments.
    #
    # @param node [Prism::Node]
    # @return [Boolean]
    def self.builder_call?(node)
      return false unless node.is_a?(Prism::CallNode)

      receiver = node.receiver
      root = receiver.is_a?(Prism::ConstantReadNode) || (receiver.is_a?(Prism::ConstantPathNode) && receiver.parent.nil?)
      root && KEPT_BUILDERS[receiver.name] == node.name
    end

    # Whether a value holds data and no class: a {literal_argument?}, an array
    # of data literals, a hash whose keys and values are data literals, or one
    # of those with `.freeze`. A constant with such a value names the same data
    # on each load, so a superclass that reads it is not stale (#533): the
    # `i18n` gem has `class Tag < Struct.new(*SUBTAGS)` with `SUBTAGS = %i[...].freeze`.
    #
    # @param node [Prism::Node]
    # @return [Boolean]
    def self.data_literal?(node)
      return true if literal_argument?(node)
      return node.elements.all? { |element| data_literal?(element) } if node.is_a?(Prism::ArrayNode)
      if node.is_a?(Prism::HashNode)
        return node.elements.all? { |pair| pair.is_a?(Prism::AssocNode) && data_literal?(pair.key) && data_literal?(pair.value) }
      end

      node.is_a?(Prism::CallNode) && node.name == :freeze && node.arguments.nil? && node.block.nil? &&
        !node.receiver.nil? && data_literal?(node.receiver)
    end

    # What a load of the file can build again (#533): the names of the file's
    # defs, and the last names of the constants it writes with a value that is
    # neither a {data_literal?} nor kept by reload ({kept_constant_write?}). A
    # multiple-assignment target always counts. {JobPlan.reads_rebuilt?} leaves
    # a superclass that reads one of them as written.
    #
    # @param program [Prism::ProgramNode] the parsed file.
    # @param unkept [Set<Symbol>] {unkept_constant_names} of the file.
    # @return [Array(Set<Symbol>, Set<Symbol>)] the def names and the constant names.
    def self.rebuilt_names(program, unkept = unkept_constant_names(program))
      defs = Set.new
      constants = Set.new
      nodes = [program]
      while (node = nodes.pop)
        nodes.concat(node.compact_child_nodes)
        if node.is_a?(Prism::DefNode)
          defs << node.name
        elsif node.is_a?(Prism::ConstantTargetNode) || node.is_a?(Prism::ConstantPathTargetNode)
          constants << node.name
        elsif CONSTANT_WRITES.any? { |type| node.is_a?(type) } && !data_literal?(node.value) &&
              !kept_constant_write?(node, unkept)
          constants << defined_constant_name(node)
        end
      end
      [defs, constants]
    end

    # The literal nodes {kept_builder?} accepts as an argument.
    LITERALS = [Prism::SymbolNode, Prism::StringNode, Prism::IntegerNode, Prism::FloatNode,
                Prism::TrueNode, Prism::FalseNode, Prism::NilNode].freeze

    # @param node [Prism::Node] one argument of a builder call.
    # @return [Boolean]
    def self.literal_argument?(node)
      return true if LITERALS.any? { |type| node.is_a?(type) }

      node.is_a?(Prism::KeywordHashNode) && node.elements.all? do |pair|
        pair.is_a?(Prism::AssocNode) && literal_argument?(pair.key) && literal_argument?(pair.value)
      end
    end

    # Whether a constant write's parent runs no code: none (`::X`), `self`, or
    # a chain of constants (`A::B`).
    #
    # @param node [Prism::Node, nil]
    # @return [Boolean]
    def self.constant_scope?(node)
      return true if node.nil? || node.is_a?(Prism::SelfNode) || node.is_a?(Prism::ConstantReadNode)

      node.is_a?(Prism::ConstantPathNode) && constant_scope?(node.parent)
    end

    # Every Prism node that writes a constant, by name or by path, with `=`,
    # `||=`, `&&=` or an operator.
    CONSTANT_WRITES = [Prism::ConstantWriteNode, Prism::ConstantOrWriteNode, Prism::ConstantAndWriteNode,
                       Prism::ConstantOperatorWriteNode, Prism::ConstantPathWriteNode, Prism::ConstantPathOrWriteNode,
                       Prism::ConstantPathAndWriteNode, Prism::ConstantPathOperatorWriteNode].freeze

    # Whether `node` is `unless defined?(X)` or `if !defined?(X)` (also
    # `if not defined?(X)`, and inside one pair of parentheses), as a statement
    # or as a modifier, whose statements define `X`: a constant write of any
    # kind, a multiple-assignment target, or a `class X` or `module X`
    # statement, at any depth (#529). The first load defined `X`, so a second
    # load skips those statements. Names match by their last segment, so
    # `defined?(A::X)` matches a write of `B::X`: that fails closed, to a
    # counted `unplaceable`. A guard whose statements do not define `X`
    # (`unless defined?(Rails)`) runs again on each load, so it does not match.
    #
    # @param node [Prism::UnlessNode, Prism::IfNode]
    # @return [Boolean]
    def self.guarded_definition?(node)
      predicate = node.predicate
      predicate = predicate.body.body.first while sole_statement_parentheses?(predicate)
      if node.is_a?(Prism::IfNode)
        return false unless predicate.is_a?(Prism::CallNode) && predicate.name == :! && predicate.receiver

        predicate = predicate.receiver
        predicate = predicate.body.body.first while sole_statement_parentheses?(predicate)
      end
      return false unless predicate.is_a?(Prism::DefinedNode) && node.statements

      guarded = predicate.value
      return false unless guarded.is_a?(Prism::ConstantReadNode) || guarded.is_a?(Prism::ConstantPathNode)

      nodes = [node.statements]
      while (inner = nodes.pop)
        nodes.concat(inner.compact_child_nodes)
        return true if defined_constant_name(inner) == guarded.name
      end
      false
    end

    # The last name of the constant `node` defines: a class or module
    # statement, a multiple-assignment target, or a {CONSTANT_WRITES} node.
    # Nil for any other node.
    #
    # @param node [Prism::Node]
    # @return [Symbol, nil]
    def self.defined_constant_name(node)
      case node
      when Prism::ClassNode, Prism::ModuleNode then node.constant_path.name
      when Prism::ConstantTargetNode, Prism::ConstantPathTargetNode then node.name
      else
        return nil unless CONSTANT_WRITES.any? { |type| node.is_a?(type) }

        node.respond_to?(:target) ? node.target.name : node.name
      end
    end

    # The calls that build an ActiveSupport callback chain: `define_callbacks`
    # and ActiveModel's `define_model_callbacks`, which calls it once per name.
    # During a reload {ReloadGuards::CallbackRedefinition} skips a chain the
    # class already has, with the options the call gives (#504).
    CALLBACK_DEFINERS = %i[define_callbacks define_model_callbacks].freeze

    # Marks each def that calls a {CALLBACK_DEFINERS} method
    # {Subject#calls_define_callbacks}, so it is `unplaceable` under reload.
    # When the class body calls such a def, the guard skips the chain it
    # defines, with the names and options a mutant changed, so the mutant
    # never reaches Rails. It would score `survived` unapplied (#504).
    #
    # It fails closed. A {CALLBACK_DEFINERS} call counts with any receiver.
    # A def that calls a marked def of the same file by name (any receiver),
    # or through `super` from a def of the same name, is marked too, so a
    # helper that calls another helper is covered. The match is by name, so a
    # same-named call in another class of the file is marked as well. The
    # whole def is marked, because any line of it can change the names or
    # options it passes. A def the class body never calls loses real verdicts
    # under reload. Still unmarked (#530): a def that only computes the names
    # or options (`define_callbacks :save, **opts`), a call through `send`,
    # `public_send`, `__send__` or `method`, and a caller in another file.
    #
    # It also marks the defs that feed a conditional skip the reload can drop
    # {Subject#makes_load_time_skip} (#543): every def that calls a
    # {CALLBACK_SKIPPERS} method (any receiver), or such a def of the file by
    # name or through `super`, when the file calls one of those defs outside
    # every def ({load_time_call?}); and every def of the file whose name a
    # load-time skip call has in its arguments ({load_time_skip_arguments}),
    # including a skip call inside such a load-time skipper def.
    # During a reload {ReloadGuards::CallbackReskipping} drops a conditional
    # skip that the first load already applied, so a mutant in such a def would
    # never reach Rails. A file that runs no such skip at load marks none, so a
    # concern's `allow_unauthenticated_access` keeps its verdicts. Still
    # unmarked (#578): a call through `send`, `public_send`, `__send__` or
    # `method`, and a caller in another file.
    #
    # @param subjects [Array<Mutineer::Subject>] subjects from one source file.
    # @param program [Prism::ProgramNode] the complete parsed file.
    # @return [void]
    def self.mark_callback_definers!(subjects, program)
      defs = []
      nodes = [program]
      while (node = nodes.pop)
        nodes.concat(node.compact_child_nodes)
        defs << node if node.is_a?(Prism::DefNode)
      end
      marked = defs_that_call(defs, CALLBACK_DEFINERS)
      subjects.each { |subject| subject.calls_define_callbacks = true if marked.include?(subject.def_node) }

      skippers = defs_that_call(defs, CALLBACK_SKIPPERS)
      helpers = skippers.map(&:name)
      suppliers = load_time_skip_arguments(program, CALLBACK_SKIPPERS + helpers)
      loaded = load_time_call?(program, helpers)
      # A skipper def the file calls at load runs its own skip calls at load too.
      if loaded
        skippers.each do |skipper|
          skipper.compact_child_nodes.each { |child| load_time_skip_arguments(child, CALLBACK_SKIPPERS + helpers, suppliers) }
        end
      end
      subjects.each do |subject|
        subject.makes_load_time_skip = true if (loaded && skippers.include?(subject.def_node)) ||
                                               suppliers.include?(subject.name)
      end
    end

    # The calls that skip an ActiveSupport callback. A conditional one is a
    # repeat on a mutant load (#543): {ReloadGuards::CallbackReskipping}.
    CALLBACK_SKIPPERS = %i[skip_callback skip_before_action skip_after_action skip_around_action].freeze

    # The defs that call one of `names`, or a def found so far by name or
    # through `super`, through any chain of such calls.
    #
    # @param defs [Array<Prism::DefNode>] every def of the file.
    # @param names [Array<Symbol>] {CALLBACK_DEFINERS} or {CALLBACK_SKIPPERS}.
    # @return [Set<Prism::DefNode>]
    def self.defs_that_call(defs, names)
      marked = Set.new
      helpers = Set.new
      loop do
        found = defs.select { |d| !marked.include?(d) && calls_callback_definer?(d, helpers, names) }
        break if found.empty?

        marked.merge(found)
        helpers.merge(found.map(&:name))
      end
      marked
    end
    private_class_method :defs_that_call

    # Whether a def calls one of `names` or one of `helpers` (any receiver),
    # or is one of `helpers` by name and calls `super`.
    #
    # @param def_node [Prism::DefNode]
    # @param helpers [Set<Symbol>] the names of the file's marked defs.
    # @param names [Array<Symbol>] the calls to look for.
    # @return [Boolean]
    def self.calls_callback_definer?(def_node, helpers, names = CALLBACK_DEFINERS)
      nodes = def_node.compact_child_nodes
      while (node = nodes.pop)
        nodes.concat(node.compact_child_nodes)
        return true if node.is_a?(Prism::CallNode) && (names.include?(node.name) || helpers.include?(node.name))
        return true if (node.is_a?(Prism::SuperNode) || node.is_a?(Prism::ForwardingSuperNode)) &&
                       helpers.include?(def_node.name)
      end
      false
    end

    # Whether the file calls one of `names` outside every def, so the call runs
    # when the file loads.
    #
    # @param node [Prism::Node]
    # @param names [Array<Symbol>]
    # @return [Boolean]
    def self.load_time_call?(node, names)
      return false if node.is_a?(Prism::DefNode)
      return true if node.is_a?(Prism::CallNode) && names.include?(node.name)

      node.compact_child_nodes.any? { |child| load_time_call?(child, names) }
    end

    # The names of the calls inside the arguments of a call of one of `names`
    # that runs when the file loads (outside every def), such as
    # `quiet_condition` in `skip_callback :save, :before, :stamp, if: quiet_condition`.
    # A block or a lambda in the arguments runs later, so it is not entered.
    # A call counts by name with any receiver, which fails closed:
    # `if: Proc.new { ... }` also marks a def of the file named `new`.
    #
    # @param node [Prism::Node]
    # @param names [Array<Symbol>] the skip calls and the file's skip defs.
    # @param found [Set<Symbol>] the names so far.
    # @return [Set<Symbol>]
    def self.load_time_skip_arguments(node, names, found = Set.new)
      return found if node.is_a?(Prism::DefNode)

      if node.is_a?(Prism::CallNode) && names.include?(node.name) && node.arguments
        stack = [node.arguments]
        while (inner = stack.pop)
          next if inner.is_a?(Prism::BlockNode) || inner.is_a?(Prism::LambdaNode)

          found << inner.name if inner.is_a?(Prism::CallNode)
          stack.concat(inner.compact_child_nodes)
        end
      end
      node.compact_child_nodes.each { |child| load_time_skip_arguments(child, names, found) }
      found
    end

    # Keeps hook defs unplaceable when the raw AST can define another method
    # with the same name and source line. Count all defs, including bodies that
    # SubjectVisitor does not select, and Ruby's explicit method creators (see
    # {.created_method_locations}). Indirect callable bodies may come from any
    # block or lambda in this file, including a stored hook block. An unknown
    # creator name blocks only those possible source lines. Instance and
    # singleton definitions can both reach singleton-class hosts, so their
    # shared name and line are ambiguous too. Run before `only` so selecting
    # one subject cannot hide a collision.
    #
    # @param subjects [Array<Mutineer::Subject>] subjects from one source file.
    # @param program [Prism::ProgramNode] the complete parsed file.
    # @return [void]
    def self.exclude_ambiguous_hook_defs!(subjects, program)
      return unless subjects.any?(&:reload_hook_call)

      counts = Hash.new(0)
      body_lines = Set.new
      indirect_names = Set.new
      nodes = [program]
      while (node = nodes.pop)
        nodes.concat(node.compact_child_nodes)
        if node.is_a?(Prism::LambdaNode) || node.is_a?(Prism::BlockNode)
          body_lines << node.location.start_line
        end
        location = if node.is_a?(Prism::DefNode)
                     [node.location.start_line, [node.name]]
                   elsif node.is_a?(Prism::CallNode)
                     created_method_locations(node)
                   end
        next unless location

        line, names = location
        if line
          names.each { |name| counts[[line, name]] += 1 }
        else
          names.each { |name| indirect_names << name }
        end
      end
      indirect_names.each { |name| body_lines.each { |line| counts[[line, name]] += 1 } }
      subjects.each do |subject|
        line = subject.def_node.location.start_line
        subject.reload_hook_call = nil if counts[[line, subject.name]] > 1 || counts[[line, nil]].positive?
      end
    end
    private_class_method :exclude_ambiguous_hook_defs!

    # The source line and names Ruby assigns to explicit method creators. A
    # block-defined method starts at the block opening and a literal lambda at
    # its arrow. A positional callable takes precedence over a supplied block.
    # Other positional bodies and block passes have an indirect source: the
    # caller checks possible block/lambda lines instead of the call line.
    # An attribute method starts at the message token, not its receiver line.
    # Literal symbol and string names are exact. A dynamic name, splat, or attr
    # writer flag may name any method on that line, represented by nil.
    #
    # @param node [Prism::CallNode] call to inspect.
    # @return [Array, nil] source line and names (a nil line means an indirect
    #   callable body), or nil for a call outside this built-in family.
    def self.created_method_locations(node)
      arguments = node.arguments&.arguments || []
      case node.name
      when :define_method, :define_singleton_method
        body = arguments[1] || node.block
        body = body.expression if body.is_a?(Prism::BlockArgumentNode)
        line = body.location.start_line if body.is_a?(Prism::BlockNode) || body.is_a?(Prism::LambdaNode)
        return [line, [literal_method_name(arguments.first)]]
      when :attr_reader, :attr_writer, :attr_accessor, :attr
        mode = { attr_reader: :reader, attr_writer: :writer, attr_accessor: :both, attr: :reader }.fetch(node.name)
        if node.name == :attr && arguments.size == 2 &&
           (arguments.last.is_a?(Prism::TrueNode) || arguments.last.is_a?(Prism::FalseNode))
          mode = arguments.last.is_a?(Prism::TrueNode) ? :both : :reader
          arguments = arguments.first(1)
        end
        names = arguments.flat_map do |argument|
          name = literal_method_name(argument)
          next [nil] unless name

          case mode
          when :reader then [name]
          when :writer then [:"#{name}="]
          else [name, :"#{name}="]
          end
        end
        [node.message_loc.start_line, names]
      end
    end
    private_class_method :created_method_locations

    # A literal method name, or nil when it depends on a runtime value.
    #
    # @param node [Prism::Node, nil] name argument.
    # @return [Symbol, nil]
    def self.literal_method_name(node)
      node.unescaped.to_sym if node.is_a?(Prism::SymbolNode) || node.is_a?(Prism::StringNode)
    end
    private_class_method :literal_method_name

    # The call statements that run each time the file loads, in order: each one
    # sits in the file's top-level statements or in a `module` or `class` body
    # reached only through such statements. A call under any `if`, `unless`,
    # `case`, `&&`, `rescue` or loop, an assignment, an argument, a def or a block
    # is not on this path. A file with a `return` outside any def or block may
    # stop before a call, so it has none (#297).
    #
    # @param program [Prism::ProgramNode] the parsed file.
    # @return [Set<Prism::CallNode>] compared by identity.
    def self.plain_path_calls(program)
      calls = Set.new.compare_by_identity
      return calls if top_level_return?(program)

      bodies = [program.statements]
      while (body = bodies.pop)
        body.body.each do |node|
          calls << node if node.is_a?(Prism::CallNode)
          bodies << node.body if (node.is_a?(Prism::ModuleNode) || node.is_a?(Prism::ClassNode)) &&
                                 node.body.is_a?(Prism::StatementsNode)
        end
      end
      calls
    end
    private_class_method :plain_path_calls

    # True when the node holds a `return` that is not inside a def, a block or a
    # lambda, so loading the file can stop early.
    #
    # @param node [Prism::Node] node to search.
    # @return [Boolean]
    def self.top_level_return?(node)
      return true if node.is_a?(Prism::ReturnNode)
      return false if node.is_a?(Prism::DefNode) || node.is_a?(Prism::BlockNode) || node.is_a?(Prism::LambdaNode)

      node.compact_child_nodes.any? { |child| top_level_return?(child) }
    end
    private_class_method :top_level_return?

    # Walks an AST, maintaining a namespace stack, emitting Subjects.
    # Nested inside Project to signal its private role.
    class SubjectVisitor < Prism::Visitor
      # Calls whose block is the body of the class they build: receiver name => method.
      CLASS_BUILDERS = { "Data" => :define, "Struct" => :new, "Class" => :new, "Module" => :new }.freeze

      # ActiveSupport::Concern calls whose block another module or class runs (see {#concern_block}).
      CONCERN_BLOCKS = %i[class_methods included prepended].freeze

      # Calls whose first argument names a method they reach (see {#placeable_hook}).
      NAME_TAKERS = %i[method instance_method send public_send __send__].freeze

      # A constant name, or a path of them; Ruby allows Unicode in both.
      CONSTANT_PATH = /\A[[:upper:]][[:word:]]*(?:::[[:upper:]][[:word:]]*)*\z/

      # A name that reads like a constant name but may not be one (#216). It is
      # the singleton class name of a `class << self` opened inside a def or a
      # block that does not build a class, or built on a written path or
      # `#<anonymous>` (`#<Class:Foo::X>` from `class Foo::X` inside `class << self`);
      # or the `X` of `module self::X` or `self::X = ...` in a def or a block. The segment carries that mark (see
      # {#singleton_name}, {#with_namespace}, {#assigned_owner}), and `scope`, the
      # def or block whose `self` the name is under, or a new object when unknown.
      class WrittenName < String
        # @return [Object] the def or block node whose `self` the name is under.
        attr_reader :scope

        # @param name [String] the name as built.
        # @param scope [Object] the def or block node whose `self` the name is under.
        def initialize(name, scope = Object.new)
          super(name)
          @scope = scope
        end
      end

      attr_reader :subjects

      # Builds a subject visitor.
      #
      # @param file [String] source file path being visited.
      # @param plain_calls [Set<Prism::CallNode>] the file's call statements on a
      #   plain path (see {Project.plain_path_calls}); only these hook calls can be placed.
      # @param unkept [Set<Symbol>] the constants reload does not keep
      #   (see {Project.unkept_constant_names}); a def in a kept value that
      #   does not run again ({Project.kept_constant_write?} and not
      #   {Project.reopened_write?}) is {Subject#not_reloaded}.
      def initialize(file, plain_calls = Set.new, unkept = Set.new)
        @file = file
        @plain_calls = plain_calls
        @unkept = unkept
        @namespace_stack = []
        @lexical_stack = [] # class/module names as written, `::X` kept (#145)
        @subjects = []
        @singleton_depth = 0
        @module_function_active = false # bareword `module_function` seen in this module body
        @module_function_names = []     # [module key, name] from `module_function :a` / `module_function def` (#98)
        @subject_keys = []              # the module key of each subject, by index
        @body = Object.new              # identifies the class/module body or builder block being visited
        @block_owner = nil
        @block_namespace = nil
        @owner_unknown = false
        @assigned = nil
        @singleton_cref = nil # the singleton class name, in a builder block inside `class << self`
        @namespace_unknown = false # the namespace is under a singleton class (#208) or a block's `self` (#229)
        @anonymous_block = false   # inside a builder block not assigned to a constant
        @self_unknown = false      # inside a def or a block that is not a builder, so `self` is not the namespace
        @self_scope = nil          # the def or block whose `self` the code runs with
        @singleton_uncertain = false # the open `class << self` was inside a def or a non-builder block
        @concern_modules = Set.new   # the {#module_key} of each module that ran `extend ActiveSupport::Concern`
        @hook_block = false          # inside a concern's `included` or `prepended` block (see {#hook_block?})
        @enclosing_subject = nil     # the subject of the def being visited, for a nested def (#290)
        @hook_call = nil             # that block's call node, when reload can place its defs (see {#placeable_hook})
        @hook_uses = Set.new         # the names that block calls outside its def bodies
        @in_superclass_block = false # inside a class statement's superclass expression (#492)
        @not_reloaded = false        # inside code a second load does not run (#503, #529)
        super()
      end

      # Promote `module_function :name` / `module_function def name` subjects to
      # singleton after the full walk — the naming call may appear before or after
      # the def, so it can't be decided at visit_def_node time (#20). Only methods
      # of the module that made the call are promoted (#98), matched by {#module_key}.
      #
      # @return [void]
      def promote_module_functions!
        return if @module_function_names.empty?

        named = @module_function_names.to_set
        @subjects.each_with_index do |s, i|
          next unless named.include?([@subject_keys[i], s.name])

          s.singleton = true
          s.reload_hook_call = nil # a module function has a second, private copy no hook def placement makes
        end
      end

      # Visits class nodes and tracks namespace nesting. A def inside the
      # superclass expression (`class X < Struct.new(:a) do ... end`) is marked
      # {Subject#in_superclass_block}: a reload keeps the live superclass, so
      # that block does not run again (#492).
      #
      # @param node [Prism::ClassNode] class node.
      # @return [void]
      def visit_class_node(node)
        with_namespace(node.constant_path) do
          visit(node.constant_path)
          if node.superclass
            saved = @in_superclass_block
            @in_superclass_block = true
            begin
              visit(node.superclass)
            ensure
              @in_superclass_block = saved
            end
          end
          visit(node.body) if node.body
        end
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
      # constant has no name, so its subjects are marked `owner_unknown`, and a
      # `module_function :name` in it promotes nothing. Elsewhere it promotes the
      # methods of the same module, matched by {#module_key}. A module that runs
      # `extend ActiveSupport::Concern` is a concern from then on in this file. A
      # `class_methods` block in its body (see {#concern_block}) is visited like a
      # builder block that builds the module's `ClassMethods`, so its defs belong to
      # that module (#252). The defs in any other such block have their owner unknown.
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
          elsif !@anonymous_block
            args.each do |arg|
              @module_function_names << [module_key, arg.value.to_sym] if arg.is_a?(Prism::SymbolNode)
              @module_function_names << [module_key, arg.name] if arg.is_a?(Prism::DefNode)
            end
          end
        end
        if node.name == :extend && (node.receiver.nil? || node.receiver.is_a?(Prism::SelfNode)) &&
           !@self_unknown && @singleton_depth.zero?
          args = node.arguments&.arguments || []
          concern = args.any? { |arg| arg.slice.delete_prefix("::") == "ActiveSupport::Concern" }
          @concern_modules << module_key if concern
        end
        case concern_block(node)
        when :owner_unknown
          hook = hook_block?(node)
          return preserving_scope do
            @hook_block ||= hook
            @hook_call, @hook_uses = placeable_hook(node) if hook
            @owner_unknown = true
            super
          end
        when :class_methods
          owner = named_owner((@block_namespace || @namespace_stack) + ["ClassMethods"])
          anonymous = false
        else
          return super unless builds_class?(node)

          anonymous = !@assigned&.first.equal?(node)
          owner = anonymous ? [nil, @namespace_stack, true] : @assigned.last
        end
        with_block_owner(owner, anonymous) do
          @self_scope = node.block
          super
        end
      end

      # A block that does not build a class may run with any `self` (`class_eval`,
      # `instance_eval`, a callback), so a `class << self` in it names a singleton
      # class Mutineer cannot be sure of (#216). A lambda is treated the same.
      #
      # @param node [Prism::BlockNode, Prism::LambdaNode] block or lambda node.
      # @return [void]
      def visit_block_node(node)
        return super if node.equal?(@self_scope) # a builder block

        saved_self = [@self_unknown, @self_scope]
        @self_unknown = true
        @self_scope = node
        super
        @self_unknown, @self_scope = saved_self
      end
      alias visit_lambda_node visit_block_node

      # Names the class a builder block assigned to this constant builds (see {#builds_class?}).
      #
      # `=`, `||=` and `&&=` store the class, so each names it; `+=` stores what `+`
      # returns, so its builder is left unnamed. A literal builder constant that
      # reload keeps without running its block again marks each def in its value
      # {Subject#not_reloaded} (#503, #528); one whose block runs again
      # ({Project.reopened_write?}) does not. So does a constant `||=`: the first
      # load set the constant, so a second load skips the value (#529).
      #
      # @param node [Prism::ConstantWriteNode, Prism::ConstantPathWriteNode, Prism::ConstantOrWriteNode,
      #   Prism::ConstantAndWriteNode, Prism::ConstantPathOrWriteNode, Prism::ConstantPathAndWriteNode]
      #   constant assignment.
      # @return [void]
      def visit_constant_write_node(node)
        saved_kept = @not_reloaded
        @not_reloaded = true if node.is_a?(Prism::ConstantOrWriteNode) || node.is_a?(Prism::ConstantPathOrWriteNode)
        if Project.kept_constant_write?(node, @unkept) && !Project.reopened_write?(node, @unkept)
          @not_reloaded = true
        end
        call = assigned_value(node.value)
        return super unless builds_class?(call)

        saved = @assigned
        @assigned = [call, assigned_owner(node)]
        begin
          super
        ensure
          @assigned = saved
        end
      ensure
        @not_reloaded = saved_kept
      end
      alias visit_constant_path_write_node visit_constant_write_node
      alias visit_constant_or_write_node visit_constant_write_node
      alias visit_constant_and_write_node visit_constant_write_node
      alias visit_constant_path_or_write_node visit_constant_write_node
      alias visit_constant_path_and_write_node visit_constant_write_node

      # Marks each def in the statements of `unless defined?(X)` or
      # `if !defined?(X)` that write or open `X` {Subject#not_reloaded}
      # ({Project.guarded_definition?}): the first load defined `X`, so a second
      # load skips those statements (#529). The predicate and an `else` branch
      # are visited as usual. The walk names no Prism field that differs between
      # Prism 1 and Prism 2.
      #
      # @param node [Prism::UnlessNode, Prism::IfNode] the conditional.
      # @return [void]
      def visit_unless_node(node)
        return super unless Project.guarded_definition?(node)

        saved = @not_reloaded
        begin
          node.compact_child_nodes.each do |child|
            @not_reloaded = saved || child.equal?(node.statements)
            visit(child)
          end
        ensure
          @not_reloaded = saved
        end
      end
      alias visit_if_node visit_unless_node

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
        saved_uncertain = @singleton_uncertain
        @singleton_uncertain ||= @self_unknown # `self` here may be another object (#216)
        super
        @module_function_active = saved_active # a visibility call in here is not the module body's
        @singleton_uncertain = saved_uncertain
        @singleton_depth -= 1
      end

      # Records a discovered method definition.
      #
      # @param node [Prism::DefNode] method definition node.
      # @return [void]
      def visit_def_node(node)
        subject = Subject.new(
          file: @file,
          namespace: (@block_namespace || @namespace_stack).dup,
          lexical: @lexical_stack.dup,
          block_owner: @block_owner,
          owner_unknown: @owner_unknown,
          hook_block: @hook_block,
          reload_hook_call: reload_hook_call_for(node),
          in_superclass_block: @in_superclass_block,
          not_reloaded: @not_reloaded,
          calls_define_callbacks: false, # set by Project.mark_callback_definers!
          makes_load_time_skip: false,   # set by Project.mark_callback_definers!
          name: node.name,
          singleton: !node.receiver.nil? || @singleton_depth.positive? || @module_function_active,
          def_node: node,
          enclosing_subject: @enclosing_subject
        )
        @subjects << subject
        @subject_keys << module_key
        saved_active = @module_function_active
        saved_self = [@self_unknown, @self_scope, @enclosing_subject]
        @self_unknown = true # `self` in a method body is the receiver it is called on
        @self_scope = node
        @enclosing_subject = subject
        super
        @module_function_active = saved_active # a visibility call in a method body runs only when it is called
        @self_unknown, @self_scope, @enclosing_subject = saved_self
      end

      private

      # The module a `module_function` call and a def are matched by: its joined
      # namespace, so a module reopened later in the file matches (#216), and
      # `module A::B` matches nested `module A; module B`. An unknown owner that an
      # anonymous builder block owns, or whose name has no {WrittenName} segment
      # and is not built only from constant names (see {#named_segment?}), may be
      # shared by another module, so it is matched only within this body (#208).
      # Otherwise a name with a {WrittenName}
      # segment is matched by that segment's scope and text, so openings under one
      # `self` match each other, but not those under another, whether the owner is
      # known or not (#229).
      #
      # @return [String, Object]
      def module_key
        namespace = @block_namespace || @namespace_stack
        written = written?(namespace)
        return @body if @owner_unknown && (@anonymous_block || !written && !namespace.all? { |s| named_segment?(s) })
        return namespace.join("::") unless written

        namespace.map { |s| s.is_a?(WrittenName) ? "#{s.scope.object_id}:#{s}" : s }.join("::")
      end

      # True when any segment of the namespace is a {WrittenName}.
      #
      # @param namespace [Array<String>] namespace segments.
      # @return [Boolean]
      def written?(namespace)
        namespace.any?(WrittenName)
      end

      # True when a namespace segment is a constant name, or a singleton class
      # (`#<Class:App::M>`) of constant names. A written path or `#<anonymous>` is
      # not, nor is a singleton class name built on one ({WrittenName}).
      #
      # @param segment [String] namespace segment.
      # @return [Boolean]
      def named_segment?(segment)
        !segment.is_a?(WrittenName) && segment.gsub(/#<Class:|>/, "").match?(CONSTANT_PATH) &&
          (segment.start_with?("#<Class:") || !segment.include?("::"))
      end

      # Runs the block with `path` pushed as the current namespace. A
      # root-anchored path (`module ::X` / `class ::X`) names the top-level X,
      # not X nested in the enclosing scope, so the namespace restarts there.
      # Bareword `module_function` state does not cross a class or module
      # boundary: each body starts without it, and the outer state returns after.
      # A class or module `X` opened inside `class << self`, even within a builder
      # block there, is a constant of the singleton class, which has no constant
      # path. It and everything nested in it is named under `#<Class:...>` with
      # its owner unknown (#208), and its body defines instance methods again.
      # A compact `Foo::X` or a top-level `::X` there is named as written, and
      # its owner is unknown too: redefine reopens the lexical chain without the
      # singleton class, so constants the body looks up through it would not resolve.
      # A `self::X` in any block is under the block's `self`, not the namespace
      # around the block (#229). In a builder block that is the built class, so
      # it is named under the builder's constant; in any other block (`class_eval`,
      # a callback) `self` may be any object, so it is named under the innermost
      # enclosing builder's constant, or else the enclosing namespace. Either way
      # the last segment is a {WrittenName}, and it and everything nested in it
      # has its owner unknown. Redefine reopens the lexical chain (`module Outer;
      # module X`), which never reaches the block's `self`; reopening X through
      # its constant with `class_eval`, as for `self::X = ...` in a builder block,
      # would drop X from `Module.nesting`, so constants its body looks up would not resolve.
      #
      # @param path [Prism::Node] the class/module constant path.
      # @yield the class or module body visit.
      # @return [void]
      def with_namespace(path)
        preserving_scope do
          name = extract_constant_name(path)
          root = root_anchored?(path)
          in_singleton = !@singleton_cref.nil? || @singleton_depth.positive?
          self_in_block = !in_singleton && !root && self_rooted?(path) && (!@block_namespace.nil? || @self_unknown)
          @namespace_stack =
            if root then [name]
            elsif in_singleton then path.is_a?(Prism::ConstantPathNode) ? [path.slice] : [singleton_name, name]
            elsif self_in_block then (@block_namespace || @namespace_stack) + [WrittenName.new(name, @self_scope)]
            else @namespace_stack + [name]
            end
          @lexical_stack += [root ? "::#{name}" : name]
          @module_function_active = false
          @block_owner = @block_namespace = @hook_call = nil
          # redefine reopens the lexical chain, which does not pass through the block's `self`
          @namespace_unknown = @owner_unknown = in_singleton || self_in_block || @namespace_unknown
          @singleton_depth = 0
          @singleton_cref = nil
          @anonymous_block = @self_unknown = @singleton_uncertain = false
          @body = Object.new
          yield
        end
      end

      # Visitor state a class/module body or builder block sets for what it contains.
      SCOPE_STATE = %i[@namespace_stack @lexical_stack @module_function_active @block_owner @block_namespace
                       @owner_unknown @singleton_depth @singleton_cref @namespace_unknown @anonymous_block @body
                       @self_unknown @self_scope @singleton_uncertain @hook_block @hook_call @hook_uses].freeze

      # Runs the block and then restores every {SCOPE_STATE} variable, so a
      # nested body's state never leaks out of it.
      #
      # @yield the nested visit.
      # @return [void]
      def preserving_scope
        saved = SCOPE_STATE.map { |name| instance_variable_get(name) }
        yield
      ensure
        SCOPE_STATE.zip(saved) { |name, value| instance_variable_set(name, value) }
      end

      # Resolves the constant an assignment writes the way Ruby does. `X` is in the
      # current namespace, `::X` and a path at the top level start from Object, and
      # `self::X` is under the current class (the built class inside a builder
      # block). In a block that does not build a class, `self` may be any object,
      # so `self::X` there has its owner unknown (#229). Any other path is
      # looked up at run time, so its owner is unknown
      # and the subject is named as written. Lexically inside `class << self`,
      # even within a builder block there, the constant belongs to the singleton
      # class, which has no constant path, so its owner is unknown too, as is
      # `X` or `self::X` in a class or module opened there (#208). A `::X` there
      # is named `X`, still unknown (see {#with_namespace}).
      #
      # @param node [Prism::Node] constant assignment.
      # @return [Array(String, Array<String>, Boolean)] owner, namespace, unknown.
      def assigned_owner(node)
        if @singleton_cref || @singleton_depth.positive?
          written = node.respond_to?(:target) ? node.target.slice : node.name.to_s
          return [nil, written.start_with?("::") ? [written.delete_prefix("::")] : [singleton_name, written], true]
        end
        unless node.respond_to?(:target)
          namespace = @namespace_stack + [node.name.to_s]
          return @namespace_unknown ? [nil, namespace, true] : named_owner(namespace)
        end

        names = []
        path = node.target
        while path.is_a?(Prism::ConstantPathNode)
          names.unshift(path.name.to_s)
          path = path.parent
        end
        # see {#with_namespace}; in a builder block too, so a later `module self::X` there matches it
        if path.is_a?(Prism::SelfNode) && (@self_unknown || @block_namespace)
          names[0] = WrittenName.new(names[0], @self_scope)
        end
        if path.is_a?(Prism::SelfNode) && (@self_unknown || @namespace_unknown && !@anonymous_block)
          return [nil, (@block_namespace || @namespace_stack) + names, true]
        end

        base =
          case path
          when nil then []
          when Prism::SelfNode then @block_namespace || @namespace_stack unless @owner_unknown
          when Prism::ConstantReadNode then [path.name.to_s] if @namespace_stack.empty?
          end
        return [nil, [node.target.slice], true] unless base

        @namespace_unknown ? [nil, base + names, true] : named_owner(base + names)
      end

      # Names the singleton class that owns the constants written here: `class << self`
      # opens that of the current class (the built class inside a builder block),
      # and a builder block inside `class << self` keeps the enclosing one. A block
      # not assigned to a constant builds a class with no name, written `#<anonymous>`.
      # Each nested `class << self` opens the singleton class of the one around it.
      # A name built on a written path or `#<anonymous>`, or opened where `self` may
      # be another object (in a def or a non-builder block), is a {WrittenName} (see {#module_key}).
      #
      # @return [String] e.g. `#<Class:App>`, or `#<Class:#<Class:App>>` two deep.
      def singleton_name
        return @singleton_cref unless @singleton_depth.positive?

        base = @anonymous_block ? @namespace_stack + ["#<anonymous>"] : @block_namespace || @namespace_stack
        name = @singleton_depth.times.reduce(base.join("::")) { |inner, _| "#<Class:#{inner}>" }
        named = !@singleton_uncertain && (@owner_unknown ? base.all? { |s| named_segment?(s) } : !written?(base))
        named ? name : WrittenName.new(name)
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

      # Sorts an ActiveSupport::Concern block by where redefine can load its defs.
      # ActiveSupport evaluates a `class_methods` block in the module's `ClassMethods`,
      # which it extends onto every includer, so the test calls `Includer.name` on
      # that module's method, not on the concern (#252). In a class or module body,
      # or a builder block, with a known owner, that module is `<namespace>::ClassMethods`.
      # The block keeps the lexical scope, so redefine reopens the concern's chain and
      # loads the mutant with `::Concern::ClassMethods.class_eval`. In a def, a block
      # that does not build a class (Rails' `concerning :Name do`), `class << self`, or
      # under an owner no constant names (an unassigned `Module.new`), no constant here
      # names that `ClassMethods`. ActiveSupport evaluates an `included` or `prepended`
      # block in each includer, which no constant names either. The call has no
      # receiver or `self`, no arguments, and a block.
      #
      # Another library can define methods with these names and run the block in
      # the module itself. So a `class_methods` block counts only in a module that ran
      # `extend ActiveSupport::Concern` earlier in this file, in this body or an earlier
      # one ({#module_key}). Any other block with these names is unplaceable: guessing
      # its owner would load a mutant where the tests never call it.
      #
      # @param node [Prism::CallNode] call node.
      # @return [Symbol, nil] `:class_methods` when redefine can name the module,
      #   `:owner_unknown` for any other Concern block, or nil for any other call.
      def concern_block(node)
        return unless CONCERN_BLOCKS.include?(node.name) && node.arguments.nil? && node.block.is_a?(Prism::BlockNode)
        return unless node.receiver.nil? || node.receiver.is_a?(Prism::SelfNode)
        placeable = node.name == :class_methods && !@self_unknown && @singleton_depth.zero? && !@owner_unknown &&
                    @concern_modules.include?(module_key)
        placeable ? :class_methods : :owner_unknown
      end

      # True for an `included` or `prepended` block of a module that ran `extend
      # ActiveSupport::Concern` earlier in this file (see {#concern_block}).
      # ActiveSupport runs the block only when a class first includes or prepends
      # the concern, so loading the file again stores the new block but never
      # runs it in a class that already has the concern (#256). Reload can still
      # place a def that sits directly in such a block (see {#placeable_hook} and
      # {#reload_hook_call_for}, #297); anything else the block defines, a nested
      # class or a builder block included, stays as the original wrote it.
      #
      # @param node [Prism::CallNode] a call {#concern_block} sorted as a concern block.
      # @return [Boolean]
      def hook_block?(node)
        %i[included prepended].include?(node.name) && @concern_modules.include?(module_key)
      end

      # The hook call and the names its block calls outside its def bodies, when
      # reload can place the block's defs (#297), else nil and an empty set. The
      # call must be on a plain path ({Project.plain_path_calls}), so the statement
      # the mutant file adds before it runs exactly when the call runs. An alias in
      # the block keeps the original body, so a block with any `alias` or
      # `alias_method` places nothing. The names come from bare calls, `self.`
      # calls and the name given to `method`, `instance_method`, `send`,
      # `public_send` or `__send__`, in every nested block and lambda too:
      # discovery cannot tell a block that runs at once from one that runs
      # later. A name such a call computes at runtime places nothing.
      #
      # @param node [Prism::CallNode] the hook call.
      # @return [Array(Prism::CallNode, Set<Symbol>), Array(nil, Set<Symbol>)]
      def placeable_hook(node)
        uses = Set.new
        return [nil, uses] unless @plain_calls.include?(node)

        nodes = [node.block.body].compact
        while (current = nodes.pop)
          next if current.is_a?(Prism::DefNode)
          return [nil, Set.new] if current.is_a?(Prism::AliasMethodNode)

          if current.is_a?(Prism::CallNode) && (current.receiver.nil? || current.receiver.is_a?(Prism::SelfNode))
            return [nil, Set.new] if current.name == :alias_method

            uses << current.name
            if NAME_TAKERS.include?(current.name) && (name_arg = current.arguments&.arguments&.first)
              # A runtime name may be any def in the block.
              return [nil, Set.new] unless name_arg.is_a?(Prism::SymbolNode) || name_arg.is_a?(Prism::StringNode)

              uses << name_arg.unescaped.to_sym
            end
          end
          nodes.concat(current.compact_child_nodes)
        end
        [node, uses]
      end

      # The hook call of the block this def sits in directly, when reload can
      # place the def (#297), else nil. The def must be in the block itself, or
      # in its `class << self` without a receiver: not in a def, a nested class
      # or module, or another block. `module_function` gives the def a second,
      # private copy, and a name the block itself uses kept the original's
      # result, so neither is placeable. An explicit receiver other than `self`
      # can be bound only inside the hook, which the extracted def does not keep.
      #
      # @param node [Prism::DefNode] the def being recorded.
      # @return [Prism::CallNode, nil]
      def reload_hook_call_for(node)
        return unless @hook_call && @self_scope.equal?(@hook_call.block) && !@module_function_active
        return if node.receiver && !node.receiver.is_a?(Prism::SelfNode)
        return if @singleton_depth > 1 || (@singleton_depth == 1 && node.receiver)
        return if @hook_uses.include?(node.name)

        @hook_call
      end

      # Runs the block with the defs it visits owned by the class a builder block builds.
      # The block body defines instance methods of that class, even inside `class << self`,
      # but its constants still land where the enclosing `class << self` puts them.
      #
      # @param owner [Array(String, Array<String>, Boolean)] the owner as written, its namespace,
      #   and whether that name is unknown.
      # @param anonymous [Boolean] true when the block is not assigned to a constant.
      # @yield the builder call visit.
      # @return [void]
      def with_block_owner(owner, anonymous)
        preserving_scope do
          @singleton_cref = singleton_name if @singleton_depth.positive?
          @block_owner, @block_namespace, @owner_unknown = owner
          @anonymous_block = anonymous
          @self_unknown = @singleton_uncertain = false
          @module_function_active = false
          @singleton_depth = 0
          @body = Object.new
          yield
        end
      end

      # True when a constant path starts with `self` (e.g. `self::X`).
      #
      # @param node [Prism::Node] constant path node.
      # @return [Boolean]
      def self_rooted?(node)
        node = node.parent while node.is_a?(Prism::ConstantPathNode)
        node.is_a?(Prism::SelfNode)
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
