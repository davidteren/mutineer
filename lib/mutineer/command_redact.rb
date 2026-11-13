# frozen_string_literal: true

# Loaded through RUBYOPT in a Ruby process that `--test-command` starts,
# before that program runs. The copier then sees a DATABASE_URL the program
# assigns itself (#457). Stdlib only, so an app Ruby older than the tool can
# load it. Not required by the gem: loading it installs the copier.

require_relative "output_filter"
require_relative "database_urls"

module Mutineer
  # Starts {OutputFilter} for one `--test-command` Ruby process (#457).
  module CommandRedact
    module_function

    # Remember dotenv URLs in this working directory and copy stdout and
    # stderr through redaction. A failed install leaves the descriptors
    # where they were, and the command still runs.
    #
    # @return [Symbol] the result of {OutputFilter.install}.
    def install
      Redaction.extra_urls = DatabaseUrls.from_files(working_directory)
      OutputFilter.install
    end

    # The working directory, or nil when it was removed. A command that runs
    # from a deleted directory must still start.
    #
    # @return [String, nil]
    def working_directory
      Dir.pwd
    rescue SystemCallError
      nil
    end
  end
end

Mutineer::CommandRedact.install
