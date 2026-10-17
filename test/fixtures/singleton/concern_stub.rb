# frozen_string_literal: true

# A stand-in for ActiveSupport::Concern (#252), which keeps the suite Rails-free.
# It takes the real name because discovery treats only a module that extends
# ActiveSupport::Concern as a concern, and it never replaces the real one.
# `class_methods` evaluates its block in the module's ClassMethods, and an
# `included` block runs in each includer, which also extends ClassMethods.
# It models what `--strategy redefine` needs only. ActiveSupport also rejects a
# second `included` block from another file, so reloading a concern from a temp
# file raises MultipleIncludedBlocks there (#257); this stub does not.
unless defined?(ActiveSupport::Concern)
  module ActiveSupport
    module Concern
      def class_methods(&)
        mod = const_defined?(:ClassMethods, false) ? const_get(:ClassMethods) : const_set(:ClassMethods, Module.new)
        mod.module_eval(&)
      end

      def included(base = nil, &block)
        return @included_block = block if block

        super
        base.extend(const_get(:ClassMethods)) if const_defined?(:ClassMethods, false)
        base.class_eval(&@included_block) if @included_block
      end
    end
  end
end
