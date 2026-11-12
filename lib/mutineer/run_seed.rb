# frozen_string_literal: true

module Mutineer
  # The seed every Minitest and RSpec run Mutineer starts itself uses, unless
  # the user sets one (#282). Coverage capture, the clean checks and the
  # mutant runs share it, so a green clean check is green in the order a
  # mutant run of the same files uses. `--test-command` runs the user's
  # command and does not use this seed (#338).
  module RunSeed
    # Default seed. Minitest reads `SEED` instead when that variable is set.
    # A random RSpec order uses this seed unless the suite sets its own.
    #
    # @api private
    PINNED_SEED = 1
  end
end
