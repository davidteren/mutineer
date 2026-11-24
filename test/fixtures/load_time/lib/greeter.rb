# frozen_string_literal: true

require_relative "greetable"

# The caller. When this file loads before the mutant, greets has already
# defined greet_alice, and reloading Greetable does not run this body again.
class Greeter
  extend Greetable
  greets :alice
end
