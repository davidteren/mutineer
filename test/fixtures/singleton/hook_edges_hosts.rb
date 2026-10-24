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
