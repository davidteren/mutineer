# frozen_string_literal: true

# A class macro that stores a lambda and a block (#493). A class that calls
# language_field while it loads keeps those copies. A later mutant of the
# macro does not change them.
class LanguageRecord
  def self.normalizers = (@normalizers ||= {})
  def self.checks = (@checks ||= [])
  def self.limits = (@limits ||= {})

  def self.language_field
    normalizers[:language] = ->(value) { value.strip }
    limits[:language] = 35
    checks << proc do |record|
      record.errors << :invalid unless record.language == record.language.downcase
    end
  end

  attr_reader :language, :errors

  def initialize(language)
    @language = self.class.normalizers[:language].call(language)
    @errors = []
    self.class.checks.each { |check| check.call(self) }
    @errors << :too_long if @language.size > self.class.limits[:language]
  end
end
