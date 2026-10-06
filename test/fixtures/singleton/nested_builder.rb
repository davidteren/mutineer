# frozen_string_literal: true

module NestedBuilderHost
  Argo = Data.define(:url) do
    Other = Class.new do
      def extra(a)
        a * 2
      end
    end
  end

  HELPER = Class.new do
    def twice(a)
      a * 2
    end

    def thrice(a)
      a * 3
    end
  end.new
end
