# frozen_string_literal: true

# Stands in for ActiveSupport::Concern, so the suite needs no Rails: the same
# `class_methods`, `included` and `append_features` behaviour, without
# dependencies or the check against a second `included` block (#252).
module MiniConcern
  def class_methods(&body)
    mod = const_defined?(:ClassMethods, false) ? const_get(:ClassMethods) : const_set(:ClassMethods, Module.new)
    mod.module_eval(&body)
  end

  def included(base = nil, &block)
    base ? super : @_included_block = block
  end

  def append_features(base)
    return false if base < self

    super
    base.extend(const_get(:ClassMethods)) if const_defined?(:ClassMethods)
    base.class_eval(&@_included_block) if instance_variable_defined?(:@_included_block)
  end
end

module ConcernGreeting
  extend MiniConcern

  class_methods do
    def greet(name)
      "Hello, #{name}" if name && name.size > 0
    end
  end

  included do
    def tag(name)
      name.size > 3 ? "long" : "short"
    end
  end
end

class ConcernGreeter
  include ConcernGreeting
end
