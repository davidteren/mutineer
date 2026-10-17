# frozen_string_literal: true

require_relative "mini_concern"

# An `included do` block runs in each class that includes the concern (#252).
module ConcernTagged
  extend MiniConcern

  included do
    def tag(name)
      name.size > 3 ? "long" : "short"
    end
  end
end

class ConcernPost
  include ConcernTagged
end
