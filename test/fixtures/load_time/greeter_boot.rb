# frozen_string_literal: true

# Stands in for Rails eager load: Greeter's class body calls greets before
# any mutant (#435). CI is not involved; the boot is.
require_relative "lib/greeter"
