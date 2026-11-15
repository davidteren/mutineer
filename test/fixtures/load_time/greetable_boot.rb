# frozen_string_literal: true

# Loads the macro and not the caller. Greeter's class body then runs in the
# test, after the mutant (#435, eager load off).
require_relative "lib/greetable"
