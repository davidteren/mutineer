# frozen_string_literal: true

module Mutineer
  # One discoverable method and its AST node.
  #
  # Location, namespace context, and the live Prism::DefNode are kept together
  # because mutators walk the def node directly.
  Subject = Struct.new(:file, :namespace, :name, :singleton, :def_node, keyword_init: true) do
    # Returns the fully-qualified subject name.
    #
    # @return [String] namespaced method name like `Billing::Invoice#total`.
    def qualified_name
      namespace.join("::") + (singleton ? "." : "#") + name.to_s
    end

    # Returns the body location for the subject, if any.
    #
    # @return [Prism::Location, nil] body location or nil for empty methods.
    def body_loc
      def_node.body&.location
    end
  end
end
