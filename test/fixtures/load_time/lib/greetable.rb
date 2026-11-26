# frozen_string_literal: true

# #435: a class macro. Greeter calls greets while the class loads. The block
# on the each line defines the instance method the test calls.
module Greetable
  def greets(*names)
    names.each { |name| define_method("greet_#{name}") { "Hello, #{name}" } }
  end
end
