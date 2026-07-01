# frozen_string_literal: true

# Basename maps to "partial" -> the failed sibling that taints partial.rb.
# Raises at load so its coverage capture errors (no coverage produced).
raise "boom from partial_test capture"
