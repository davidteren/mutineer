# frozen_string_literal: true

require_relative "concern_stub"

# #297: defs in an `included` block, in each form reload can place. The hosts
# live in hook_edges_hosts.rb: a reload runs this file again, so a host here
# would be rebuilt and get the mutant only as a lazy includer.
module HookEdges
  extend ActiveSupport::Concern
  STEP = 1
  REGISTRY = [] unless const_defined?(:REGISTRY, false)

  included do
    HookEdges::REGISTRY << self

    def bumped(x)
      x + STEP
    end

    def self.made
      STEP + 6
    end

    class << self
      def tagged(x)
        x * 2
      end
    end

    private

    def secret(x)
      x - 1
    end

    public

    def revealed(x)
      secret(x)
    end
  end
end
