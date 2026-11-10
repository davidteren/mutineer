# frozen_string_literal: true

# A Rails-free stand-in for class-body macros: each macro call records itself.
module MacroDsl
  def validations = (@validations ||= [])
  def cascades = (@cascades ||= [])
  def validates(attr, **opts) = validations << [attr, opts]
  def has_many(name, dependent: nil) = (cascades << name if dependent == :destroy)
end

class Widget
  extend MacroDsl
  validates :name, presence: true
  has_many :parts, dependent: :destroy

  def initialize(name) = @name = name
  def valid? = self.class.validations.none? { |attr, o| o[:presence] && instance_variable_get("@#{attr}").to_s.empty? }
end
