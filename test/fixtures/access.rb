# frozen_string_literal: true

class Access
  def guest?(user)
    !user
  end
end
