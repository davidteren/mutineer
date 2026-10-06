# frozen_string_literal: true

module ModuleNewHost
  Helpers = Module.new do
    def calc(a)
      a * 2
    end
    module_function :calc

    module_function

    def twice(a)
      a * 2
    end
  end
end
