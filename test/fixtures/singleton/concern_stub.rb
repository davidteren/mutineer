# frozen_string_literal: true

# A stand-in for ActiveSupport::Concern (#252), which keeps the suite Rails-free.
# It takes the real name because discovery treats only a module that extends
# ActiveSupport::Concern as a concern, and it never replaces the real one.
# `class_methods` evaluates its block in the module's ClassMethods. Like
# ActiveSupport, it stores one `included` block and raises MultipleIncludedBlocks
# for a second one from another file (#256), and it runs that block and extends
# ClassMethods only when a class first includes the concern.
unless defined?(ActiveSupport::Concern)
  module ActiveSupport
    module Concern
      class MultipleIncludedBlocks < StandardError; end

      def class_methods(&)
        mod = const_defined?(:ClassMethods, false) ? const_get(:ClassMethods) : const_set(:ClassMethods, Module.new)
        mod.module_eval(&)
      end

      def append_features(base)
        return false if base < self

        super
        base.extend(const_get(:ClassMethods)) if const_defined?(:ClassMethods, false)
        base.class_eval(&@_included_block) if instance_variable_defined?(:@_included_block)
      end

      def included(base = nil, &block)
        return super if base

        if instance_variable_defined?(:@_included_block)
          raise MultipleIncludedBlocks if @_included_block.source_location != block.source_location
        else
          @_included_block = block
        end
      end
    end
  end
end
