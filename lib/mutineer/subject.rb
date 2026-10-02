# frozen_string_literal: true

module Mutineer
  # One discoverable method and its AST node.
  #
  # Location, namespace context, and the live Prism::DefNode are kept together
  # because mutators walk the def node directly. `namespace` names the owner
  # (`module ::X` inside `Outer` owns into `X`); `lexical` is the class/module
  # chain as written (`["Outer", "::X"]`), which the redefine strategy needs to
  # rebuild the same Module.nesting as a whole-file reload (#145).
  Subject = Struct.new(:file, :namespace, :name, :singleton, :def_node, :lexical, :block_owner,
                       keyword_init: true) do
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

    # Returns the body location for the subject, if any.
    #
    # @return [Prism::Location, nil] body location or nil for empty methods.
    def body_loc
      def_node.body&.location
    end
  end
end
