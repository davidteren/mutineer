# frozen_string_literal: true

require "stringio"

module Mutineer
  # Raised when the target project asks for a framework whose gem isn't present.
  # rspec is NOT a Mutineer dependency — it must come from the project's bundle.
  class FrameworkUnavailable < StandardError; end

  module TestRunners
    # Child-process-only RSpec runner, mirroring MinitestIntegration's contract:
    # run the given spec files and return 0 (all passed) / 1 (any failure).
    #
    # rspec-core is required LAZILY here, never at load time, so Mutineer keeps
    # zero runtime gem deps; a missing rspec raises a clear Mutineer error.
    #
    # No `rescue` around the run itself: Isolation.run's fork block is the single
    # exception boundary (any exception there -> exit 2), keeping the 0/1 contract.
    module RSpec
      # `spec_files` is one path or an Array of paths (coverage selection passes
      # the covering subset). All are loaded+run in a single RSpec invocation.
      def self.run(spec_files)
        require_rspec!

        # rspec/autorun (if a spec_helper required it) installs an at_exit run;
        # neutralise it like Minitest.autorun so it never double-fires.
        ::RSpec::Core::Runner.disable_autorun!

        # Drop any RSpec world/configuration inherited across runs in one process
        # (e.g. successive forks of a booted parent) so examples never accumulate.
        ::RSpec.reset

        # Silence RSpec's formatter output (and any stray puts/deprecations) so it
        # never pollutes Mutineer's report streams. The formatter writes to the
        # passed IO; $stdout/$stderr are redirected to catch everything else.
        sink = StringIO.new
        orig_out = $stdout
        orig_err = $stderr
        $stdout = sink
        $stderr = sink
        begin
          status = ::RSpec::Core::Runner.run(["--no-color", *Array(spec_files)], sink, sink)
        ensure
          $stdout = orig_out
          $stderr = orig_err
        end

        status.zero? ? 0 : 1
      end

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
