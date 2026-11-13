# frozen_string_literal: true

# The class body calls adult?(true), so a reload runs the continuation before
# any test. The tests either call it again or only call it with false.
class ContinuationLoad
  def self.adult?(verified)
    verified &&
      20 > 17
  end
  LOADED = adult?(true)
end
