# frozen_string_literal: true

# #145: a root-anchored class inside a module reads a constant from that module.
# Ruby's lexical scope for `scale` is [RootTop, RootOuter], so FACTOR resolves.
module RootOuter
  FACTOR = 2

  class ::RootTop
    def scale(x)
      x * FACTOR
    end
  end
end
