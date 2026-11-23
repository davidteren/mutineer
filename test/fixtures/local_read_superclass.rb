# frozen_string_literal: true

# R16 of the #512 plan: a superclass that is a bare variable read. The earlier
# line runs again on reload and builds a new class, so the reload is not
# wrapped and errors with "superclass mismatch", as in 1.9.0.
base = Struct.new(:v) do
  def in_block? = v == 1
end
class LocalRow < base
  def three? = v == 3
end
LOCAL_ROW_BASE = base
