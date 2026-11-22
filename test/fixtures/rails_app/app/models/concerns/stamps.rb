# frozen_string_literal: true

# #479: adds the same `&:stamp` callback as the class body that includes it.
module Stamps
  extend ActiveSupport::Concern

  included do
    before_save(&:stamp)
  end
end
