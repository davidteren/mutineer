# frozen_string_literal: true

module Mutineer
  # One discoverable method and its AST node.
  #
  # Location, namespace context, and the live Prism::DefNode are kept together
  # because mutators walk the def node directly. `namespace` names the owner
  # (`module ::X` inside `Outer` owns into `X`); `lexical` is the class/module
  # chain as written (`["Outer", "::X"]`), which the redefine strategy needs to
  # rebuild the same Module.nesting as a whole-file reload (#145). `block_owner`
  # is the constant a `Data.define`-style block is assigned to, as written, or
  # the `ClassMethods` of a concern's `class_methods` block (#252);
  # `owner_unknown` is true when the class that owns the method cannot be named
  # (an unassigned builder block, or a concern block whose class or module no
  # constant names, such as an `included` block that runs in each includer),
  # so the redefine strategy cannot load a mutant onto it. `hook_block` is true
  # for a def anywhere inside a concern's `included` or `prepended` block, which
  # ActiveSupport runs only when a class first includes the concern, so a
  # reload of the file does not reach a class that already has it (#256).
  # `reload_hook_call` is the `included` or `prepended` call node of such a
  # block when reload can still place the def: the mutant file stores the
  # mutated def just before that call, and the child loads it into each class
  # that has the method (#297). It is nil when reload cannot place the def, even
  # when `hook_block` is true (see docs/json-schema.md for the cases).
  # `enclosing_subject` is the subject of the `def` whose body holds this one,
  # or nil, so the redefine strategy can load each enclosing method too (#290).
  # `macro_node` is the class-body call when this subject is a macro, not a
  # method. It is nil for a `def`. A macro keeps `def_node` nil and `singleton`
  # false. Its qualified name uses `.` (#397).
  Subject = Struct.new(:file, :namespace, :name, :singleton, :def_node, :lexical, :block_owner, :owner_unknown,
                       :hook_block, :reload_hook_call, :enclosing_subject, :macro_node, keyword_init: true) do
    # Returns the fully-qualified subject name.
    #
    # A method uses `#` or `.` from {#singleton}. A macro always uses `.`,
    # because `singleton` stays false for a class-body call.
    #
    # @return [String] namespaced name like `Billing::Invoice#total` or
    #   `Card.has_many(:entropies)`.
    def qualified_name
      separator = macro_node ? "." : (singleton ? "." : "#")
      namespace.join("::") + separator + name.to_s
    end

    # True when this subject is a class-body macro call.
    #
    # @return [Boolean]
    def macro?
      !macro_node.nil?
    end

    # The node whose source location identifies this subject.
    #
    # A method uses its def node. A macro uses its call node. Callers that
    # only need a location, such as the subject ordinal, use this. Callers
    # that edit a method body keep using {#def_node}.
    #
    # @return [Prism::Node, nil]
    def node
      def_node || macro_node
    end

    # Class/module chain as written in the source, for textual wrappers. Falls
    # back to `namespace` for subjects built without one.
    #
    # @return [Array<String>] names; a root-anchored element keeps its `::`.
    def lexical_namespace
      lexical || namespace
    end

    # True when the strategy cannot load a mutant of this method where the tests
    # call it, so the mutant is not run. Redefine needs a named owner. Reload
    # loads the whole file again, which redefines everything except what a
    # concern's `included` or `prepended` block defines: that block does not run
    # again in a class that already includes the concern. Reload places such a
    # def only when discovery found its {#reload_hook_call} (#297).
    #
    # @param strategy [String] `"reload"` or `"redefine"`.
    # @return [Boolean]
    def unplaceable?(strategy)
      strategy == "redefine" ? owner_unknown == true : hook_block == true && reload_hook_call.nil?
    end

    # Returns the body location for the subject, if any.
    #
    # @return [Prism::Location, nil] body location, or nil for an empty method
    #   or a macro subject.
    def body_loc
      def_node&.body&.location
    end
  end
end
