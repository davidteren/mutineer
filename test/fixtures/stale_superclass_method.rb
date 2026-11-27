# frozen_string_literal: true

# #533: the superclass is a builder method of this file, which builds a new
# class on each call.
def self.point_base
  Struct.new(:x) do
    def big? = x > 1
  end
end

class BuiltPoint < point_base
  def small? = x < 1
end
