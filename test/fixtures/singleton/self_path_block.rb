# frozen_string_literal: true

class SelfPathTarget; end

module SelfPathApp
  SelfPathTarget.class_eval do
    module self::Calc
      def self.sum = 1 + 1
    end
  end

  Built = Class.new do
    module self::Calc
      def self.product = 2 * 3
    end
  end
end
