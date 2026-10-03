# frozen_string_literal: true

# A serial class that kills under `>=` and a parallel class in one run:
# Minitest runs the serial class first, so the stop at the first failure
# still skips test_b_run_at_limit's exit and the parallel class.
require_relative "gate_test"
require_relative "looper_parallel_test"
