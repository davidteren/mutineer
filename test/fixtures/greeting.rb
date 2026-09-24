# frozen_string_literal: true

class Greeting
  def name_of(user)
    user&.name
  end
end
