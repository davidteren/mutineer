# frozen_string_literal: true

# A plain PORO that stands in for an app class autoloaded by the boot file.
class Widget
  def price(n)
    n * 2
  end

  def total(a, b)
    a + b
  end

  # No test exercises this method, so its mutations must come back :no_coverage
  # in boot mode — proving boot-mode coverage selection actually runs.
  def discount(a, b)
    a - b
  end
end
