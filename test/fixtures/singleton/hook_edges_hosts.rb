# frozen_string_literal: true

require_relative "hook_edges"

# #297: classes that include HookEdges before any mutant loads. A run loads
# this file in the parent (require_paths), so each host already has the
# block's methods and only the placed def can reach it.
class HookEdgesHost
  include HookEdges
end

class HookEdgesOverride < HookEdgesHost
  def bumped(x)
    x + 100
  end
end

module HookEdgesMixin
  include HookEdges
end

class HookEdgesMixinHost
  include HookEdgesMixin
end

HOOK_EDGES_ANONYMOUS = [Class.new { include HookEdges }].freeze

# Wrappers must keep dispatching through the mutated method with `super`.
module HookEdgesWrapper
  def bumped(x)
    super
  end

  private

  def secret(x)
    super
  end
end

module HookEdgesSingletonWrapper
  def made
    super
  end

  def tagged(x)
    super
  end
end

class HookEdgesWrappedHost
  include HookEdges
  prepend HookEdgesWrapper
  singleton_class.prepend HookEdgesSingletonWrapper
end

# The concern's instance methods belong to this object's singleton class.
HOOK_EDGES_OBJECT = Object.new
class << HOOK_EDGES_OBJECT
  include HookEdges
end
