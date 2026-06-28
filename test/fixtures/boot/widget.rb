# frozen_string_literal: true

# A plain PORO that stands in for an app class autoloaded by the boot file.
class Widget
  def price(n)
    n * 2
  end

  def total(a, b)
    a + b
  end
end
