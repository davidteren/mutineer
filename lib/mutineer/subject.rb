# frozen_string_literal: true

module Mutineer
  # One discoverable method: its location, namespace context, and the live
  # Prism::DefNode mutators walk. Struct (not Data) because def_node is a live
  # AST node — value-equality would be hollow, so we don't promise it.
  Subject = Struct.new(:file, :namespace, :name, :singleton, :def_node, keyword_init: true) do
    # e.g. "Billing::Invoice#total", "Billing::Invoice.build".
    # Top-level (empty namespace) -> "#name" (no :: prefix).
    def qualified_name
      namespace.join("::") + (singleton ? "." : "#") + name.to_s
    end

    # nil for empty methods (def empty; end).
    def body_loc
      def_node.body&.location
    end
  end
end
