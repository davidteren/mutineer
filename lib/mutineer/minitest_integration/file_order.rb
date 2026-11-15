# frozen_string_literal: true

module Mutineer
  class MinitestIntegration
    # Runs each file's test classes in the order of `rank`, and shuffles the
    # classes inside one file with Minitest.seed alone (#203, #282). A
    # shuffle of the whole class list would put the same file's classes in a
    # different order when another file is added, so a clean check of one
    # file and a mutant run of several files would not share an order.
    # Minitest still runs serial classes before `parallelize_me!` classes.
    # Only the child's own class list gets {FileOrder}.
    #
    # @api private
    # @param rank [Hash{Class => Integer}] each class's file position.
    # @return [void]
    def self.keep_file_order(rank)
      FileOrder.rank = rank
      ::Minitest::Runnable.runnables.extend(FileOrder)
    end

    # Extends the list of test classes. `shuffle` orders files by {rank} and
    # shuffles each file on its own.
    module FileOrder
      class << self
        # Each test class's file position.
        #
        # @return [Hash{Class => Integer}, nil]
        attr_accessor :rank
      end

      # Files in rank order. Classes that share a file are shuffled with
      # `Random.new(Minitest.seed)`, so their order does not depend on the
      # other files in the run. A nil seed keeps load order.
      #
      # @return [Array<Class>]
      def shuffle(*)
        rank = FileOrder.rank || {}
        seed = ::Minitest.seed
        grouped = group_by { |klass| rank.fetch(klass, rank.size) }
        grouped.sort.flat_map do |_index, classes|
          next classes if classes.size < 2 || seed.nil?

          classes.shuffle(random: Random.new(seed.to_i))
        end
      end

      # Minitest 5.15 and older drop empty classes before the shuffle, so the
      # filtered list keeps the file order too.
      #
      # @return [Array<Class>]
      def reject(...)
        super.extend(FileOrder)
      end
    end
  end
end
