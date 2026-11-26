# frozen_string_literal: true

# Has a paired test and also matches the concerns→controllers map (#382 AE6).
module Authentication
  def signed_in_offset(n)
    n + 1
  end
end
