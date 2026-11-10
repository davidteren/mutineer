# frozen_string_literal: true

require_relative "../test_helper"
require "tempfile"

class DefBodyInvariantTest < Minitest::Test
  SOURCE = <<~RUBY
    class Card < ApplicationRecord
      validates :title, presence: true, length: { maximum: 10 + 2 }
      has_many :entropies, dependent: :destroy
      scope :active, -> { where(active: true).where("x > 1") }
      before_save { self.n = (n || 0) + 1 if a && b }
      enum :status, { on: 0, off: 1 }
      LIMIT = [1, 2].map { |x| x * 2 }
      def total(a, b) = a + b > 3 && !a.nil?
    end
  RUBY

  def test_no_def_operator_mutates_outside_a_def_body
    Tempfile.create(["probe4", ".rb"]) do |file|
      file.write(SOURCE)
      file.flush
      subjects = Mutineer::Project.discover([file.path], macros: true)
      ranges = subjects.filter_map { |subject| subject.def_node&.body&.location }
                       .map { |location| location.start_offset...location.end_offset }
      names = Mutineer::MutatorRegistry::ALL.keys - Mutineer::MutatorRegistry::MACRO_NAMES
      names.each do |name|
        operator = Mutineer::MutatorRegistry::ALL.fetch(name)
        subjects.each do |subject|
          operator.new.mutations_for(subject, SOURCE).each do |mutation|
            inside = ranges.any? { |range| range.cover?(mutation.start_offset) && mutation.end_offset <= range.end }
            assert inside, "#{name} edited outside a def body. EnumRedeclaration, CallbackReskipping, " \
                           "RepeatedCallbacks (#391) rely on def operators never editing the class body"
          end
        end
      end
    end
  end
end
