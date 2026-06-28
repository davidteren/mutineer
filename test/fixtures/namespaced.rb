# frozen_string_literal: true

module Shop
  # Referenced UNQUALIFIED inside the method below. Under the old 7b
  # (class_eval(string), nesting == [Order]) this raised NameError; the full
  # namespace-nesting wrapper resolves it exactly as 7a's whole-file load does.
  RATE = 1 unless defined?(RATE) # guard: 7a reloads the whole file each mutant

  class Order
    def total(price, qty)
      base = price * qty   # non-final statement => statement_removal target
      base * RATE          # references enclosing-namespace constant; *->/ is a
                           # no-op since RATE == 1, so this mutation SURVIVES
    end
  end
end
