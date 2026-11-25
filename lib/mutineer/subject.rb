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
  # `in_superclass_block` is true for a def inside a class statement's
  # superclass expression, such as `class X < Struct.new(:a) do ... end`. A
  # reload keeps the live superclass, so that block does not run again (#492).
  # `not_reloaded` is true for a def that a second load of its file does not
  # define again, so reload cannot place a mutant in it. It is set for a def
  # inside the block of a literal class builder constant whose class reload
  # keeps ({Project.kept_constant_write?}) and whose block it does not run again
  # ({Project.reopened_write?}), such as `Point = Struct.new(:x) do ... end`
  # with an `alias_method` in the block (#503, #528); for a def inside the
  # value of a constant `||=` write; and for a def inside the statements of
  # `unless defined?(X)` or `if !defined?(X)` that write or open `X`
  # ({Project.guarded_definition?}). The first load set the constant, so the
  # second load skips that code (#529).
  # `calls_define_callbacks` is true for a def that calls `define_callbacks`
  # or `define_model_callbacks` anywhere in its body (a nested def or block
  # too), or calls another such def of the same file by name or through
  # `super`, through any chain of such calls ({Project.mark_callback_definers!}). A reload skips a chain the class
  # already has, so a mutant there never reaches Rails (#504).
  # `makes_load_time_skip` is true for a def that calls `skip_callback` or a
  # `skip_*_action` (or such a def of the same file), when the file runs one of
  # those defs while it loads, and for a def whose name a load-time skip call
  # has in its arguments ({Project.mark_callback_definers!}). A reload drops a
  # conditional skip the first load already applied, so a mutant there would
  # never reach Rails (#543).
  Subject = Struct.new(:file, :namespace, :name, :singleton, :def_node, :lexical, :block_owner, :owner_unknown,
                       :hook_block, :reload_hook_call, :enclosing_subject, :in_superclass_block,
                       :not_reloaded, :calls_define_callbacks, :makes_load_time_skip, keyword_init: true) do
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
    # again in a class that already includes the concern. Reload places such a
    # def only when discovery found its {#reload_hook_call} (#297). Reload also
    # cannot place a def inside a superclass expression ({#in_superclass_block},
    # #492), a def that a second load does not define again ({#not_reloaded}:
    # a kept builder block that does not run again, #528, or a `||=` value or
    # a `defined?` guard, #529), a def that calls `define_callbacks`
    # ({#calls_define_callbacks}, #504), or a def that feeds a skip the file runs
    # while it loads ({#makes_load_time_skip}, #543).
    #
    # @param strategy [String] `"reload"` or `"redefine"`.
    # @return [Boolean]
    def unplaceable?(strategy)
      return owner_unknown == true if strategy == "redefine"

      (hook_block == true && reload_hook_call.nil?) || in_superclass_block == true || not_reloaded == true ||
        calls_define_callbacks == true || makes_load_time_skip == true
    end

    # Returns the body location for the subject, if any.
    #
    # @return [Prism::Location, nil] body location or nil for empty methods.
    def body_loc
      def_node.body&.location
    end
  end
end
