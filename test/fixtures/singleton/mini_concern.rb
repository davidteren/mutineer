# frozen_string_literal: true

# Stands in for ActiveSupport::Concern under its own name, so the suite needs no
# Rails and discovery sees the same `extend ActiveSupport::Concern` as in an app:
# the same `class_methods`, `included` and `append_features` behaviour, including
# the check that rejects a second `included` block from another file (#252).
module ActiveSupport
  module Concern
    def class_methods(&body)
      mod = const_defined?(:ClassMethods, false) ? const_get(:ClassMethods) : const_set(:ClassMethods, Module.new)
      mod.module_eval(&body)
    end

    def included(base = nil, &block)
      return super if base
      if instance_variable_defined?(:@_included_block) && @_included_block.source_location != block.source_location
        raise "Cannot define multiple 'included' blocks for a Concern"
      end

      @_included_block = block
    end

    def append_features(base)
      return false if base < self

      super
      base.extend(const_get(:ClassMethods)) if const_defined?(:ClassMethods)
      base.class_eval(&@_included_block) if instance_variable_defined?(:@_included_block)
    end
  end
end
