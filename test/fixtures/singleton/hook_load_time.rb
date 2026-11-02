# frozen_string_literal: true

require_relative "concern_stub"

# #348: code after the hook block calls its def while the file loads, so the
# mutated def must be in place before the rest of the file runs.
module HookLoadTime
  extend ActiveSupport::Concern

  included do
    def doubled(x)
      x * 2
    end
  end
end

module HookLoadTimeWrap
  extend ActiveSupport::Concern

  prepended do
    def bumped(x)
      x + 1
    end
  end
end

class HookLoadTimeHost
  include HookLoadTime
  prepend HookLoadTimeWrap
end

HOOK_LOAD_TIME_TOTAL = HookLoadTimeHost.new.doubled(2)
HOOK_LOAD_TIME_BUMPED = HookLoadTimeHost.new.bumped(2)
