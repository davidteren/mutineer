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
  # ActiveSupport runs only when a class first includes the concern, so the
  # reload strategy cannot load a mutant onto it either (#256).
  Subject = Struct.new(:file, :namespace, :name, :singleton, :def_node, :lexical, :block_owner, :owner_unknown,
                       :hook_block, keyword_init: true) do
    # Returns the fully-qualified subject name.
    #
    # @return [String] namespaced method name like `Billing::Invoice#total`.
    def qualified_name
      namespace.join("::") + (singleton ? "." : "#") + name.to_s
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
    # again in a class that already includes the concern.
    #
    # @param strategy [String] `"reload"` or `"redefine"`.
    # @return [Boolean]
    def unplaceable?(strategy)
      strategy == "redefine" ? owner_unknown == true : hook_block == true
    end

    # Returns the body location for the subject, if any.
    #
    # @return [Prism::Location, nil] body location or nil for empty methods.
    def body_loc
      def_node.body&.location
    end
  end
end
