# frozen_string_literal: true

module PathUser
end

module PathAdmin
  PathUser::Permission = Data.define(:r) do
    def allow?(a)
      a * 2
    end
  end
end

class PathRelease
  self::Gate = Struct.new(:o) do
    def open?(a)
      a * 2
    end

    self::Latch = Struct.new(:o) do
      def shut?(a)
        a * 2
      end
    end
  end
end
