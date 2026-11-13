# frozen_string_literal: true

# The each line runs when apply is called with an empty array. The block does
# not. A later call with an element runs the block (#435 review).
module ApplyEach
  def self.apply(xs)
    xs.each { |x| keep("original") }
  end

  def self.keep(value)
    @kept = value
  end

  def self.kept
    @kept
  end
end
