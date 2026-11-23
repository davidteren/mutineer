# frozen_string_literal: true

# #504: adds a callback to a chain that the including class defines itself.
module OwnStamps
  extend ActiveSupport::Concern

  included do
    before_save :stamp
  end
end
