# frozen_string_literal: true

module Mutineer
  # Pins the environment Rails and Spring read during a mutant run.
  #
  # Rails reads +PARALLEL_WORKERS+ inside +parallelize+ and uses it instead of
  # the +workers:+ argument. A value of 1 keeps that run in one process.
  # +--test-command+ also sets +DISABLE_SPRING+ so the Spring preloader does
  # not start. The caller prints the replacement line once, then puts the
  # process value back when the run ends.
  module RailsRunEnv
    # Value of +PARALLEL_WORKERS+ that keeps Rails test workers off.
    PARALLEL_WORKERS = "1"

    # Value of +DISABLE_SPRING+ that stops the Spring preloader.
    DISABLE_SPRING = "1"

    # Sets +PARALLEL_WORKERS+ to {PARALLEL_WORKERS} in this process.
    # Prints one line when the previous value is set and is not already 1.
    #
    # @return [void]
    def self.pin_process!
      current = ENV["PARALLEL_WORKERS"]
      warn(replacement_line(current)) if replace?(current)
      ENV["PARALLEL_WORKERS"] = PARALLEL_WORKERS
      nil
    end

    # Puts the caller's +PARALLEL_WORKERS+ back. +nil+ means it was unset.
    #
    # @param previous [String, nil]
    # @return [void]
    def self.restore_process!(previous)
      if previous.nil?
        ENV.delete("PARALLEL_WORKERS")
      else
        ENV["PARALLEL_WORKERS"] = previous
      end
      nil
    end

    # Forces +PARALLEL_WORKERS+ on a child environment.
    # +spring+ also sets +DISABLE_SPRING+. The hash is the spawn delta or the
    # full daemon environment. This does not change the parent process.
    #
    # @param env [Hash{String => String, nil}]
    # @param spring [Boolean] set +DISABLE_SPRING+ when true.
    # @return [void]
    def self.pin_child!(env, spring: false)
      env["PARALLEL_WORKERS"] = PARALLEL_WORKERS
      env["DISABLE_SPRING"] = DISABLE_SPRING if spring
      nil
    end

    # True when Mutineer must replace a +PARALLEL_WORKERS+ value the user set.
    #
    # @param current [String, nil]
    # @return [Boolean]
    def self.replace?(current)
      !current.nil? && current != PARALLEL_WORKERS
    end

    # The one line printed when {replace?} is true.
    #
    # @param current [String]
    # @return [String]
    def self.replacement_line(current)
      "[mutineer] PARALLEL_WORKERS was #{current.inspect}; using 1 so each mutant's tests run in one process."
    end
  end
end
