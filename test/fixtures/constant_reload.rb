# frozen_string_literal: true

# #364 repro: each reload mutant loads this file again, so both constants are
# assigned twice. That must not print Ruby's redefinition warnings.
module ConstantReload
  GREETING = "Hello"
  LIMIT = 10

  def self.greet(name) = name.size > LIMIT ? GREETING : "#{GREETING}, #{name}!"
end
