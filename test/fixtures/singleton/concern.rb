# frozen_string_literal: true

require_relative "mini_concern"

# A `class_methods do` block runs in the concern's ClassMethods module (#252).
module ConcernGreeting
  extend MiniConcern

  class_methods do
    def greet(name)
      "Hello, #{name}" if name && name.size > 0
    end
  end
end

class ConcernGreeter
  include ConcernGreeting
end
