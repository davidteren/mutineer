# frozen_string_literal: true

# The smallest shape of the controller in issue #434: one branch the test
# checks, and an else branch that returns raw bytes.
class BinaryBody
  def show(id)
    if id == "missing"
      :not_found
    else
      "\xDA\xFF".b
    end
  end
end
