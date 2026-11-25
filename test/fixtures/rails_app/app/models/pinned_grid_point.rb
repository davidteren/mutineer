# frozen_string_literal: true

# #528: a subclass in another file. An initializer loads it at boot, so it
# exists before any mutant of grid_point.rb loads.
class PinnedGridPoint < GridPoint
end
