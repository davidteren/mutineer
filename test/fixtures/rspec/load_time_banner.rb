# frozen_string_literal: true

# A source file that prints when it loads, as some libraries do with a banner.
# It has no arithmetic, so it adds no mutants of its own.
puts "hello from load time"

# Placeholder constant so the file defines something.
RSPEC_LOAD_TIME_BANNER = true
