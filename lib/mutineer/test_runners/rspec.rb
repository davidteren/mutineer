# frozen_string_literal: true

require "stringio"

module Mutineer
  # Raised when the target project asks for a framework whose gem isn't present.
  # rspec is NOT a Mutineer dependency — it must come from the project's bundle.
  class FrameworkUnavailable < StandardError; end

  module TestRunners
    # Child-process-only RSpec runner.
    #
    # Mirrors MinitestIntegration's contract: run the given spec files and
    # return 0 (all passed) or 1 (any failure).
    module RSpec
      # Runs the given RSpec files.
      #
      # @param spec_files [String, Array<String>] one file or many files.
      # @param stop_at_first_failure [Boolean] when true, the run ends at the
      #   first failing example (RSpec `--fail-fast`).
      # @return [Integer] 0 on success, 1 on failure.
      def self.run(spec_files, stop_at_first_failure: false)
        require_rspec!

        ::RSpec::Core::Runner.disable_autorun!
        ::RSpec.reset

        sink = StringIO.new
        orig_out = $stdout
        orig_err = $stderr
        $stdout = sink
        $stderr = sink
        args = ["--no-color"]
        args << "--fail-fast" if stop_at_first_failure
        begin
          status = ::RSpec::Core::Runner.run([*args, *Array(spec_files)], sink, sink)
        ensure
          $stdout = orig_out
          $stderr = orig_err
        end

        status.zero? ? 0 : 1
      end

      # Requires rspec-core from the project under test.
      #
      # @api private
      def self.require_rspec!
        require "rspec/core"
      rescue LoadError
        raise Mutineer::FrameworkUnavailable,
              "framework 'rspec' requested but rspec is not available; " \
              "add rspec to the project under test (its bundle), then retry"
      end
    end
  end
end
