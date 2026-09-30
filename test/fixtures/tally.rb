# frozen_string_literal: true

class Tally
  def sum(items)
    total = 0
    items.each { |item| total += item }
    total
  end
end
