# frozen_string_literal: true

class Crate < ApplicationRecord
  has_many :crate_items, dependent: :destroy
  validates :label, presence: true
end
