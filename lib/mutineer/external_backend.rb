# frozen_string_literal: true

require "fileutils"
require "shellwords"
require "tempfile"
require "tmpdir"
require_relative "child_cause"
require_relative "result"
require_relative "rails_run_env"
require_relative "redaction"

module Mutineer
  # Raised when the smoke check (the unmutated suite) is not green, so the run
  # aborts before scoring — a broken environment must never be reported as strong
  # tests. The CLI maps this to a runtime error (exit 1), not a usage error.
  class SmokeCheckError < StandardError; end

  # External execution backend. Runs the user's `--test-command` as a subprocess
  # in the app's own runtime (whatever Ruby its bundle resolves to), so mutineer
  # (Ruby ≥ 3.4) can mutation-test apps pinned to an older Ruby.
  #
  # This is deliberately NOT a `TestRunners` framework adapter: those return an
  # Integer 0/1 from inside a fork and are dispatched by framework name. This is a
  # whole backend — it spawns a process, enforces a wall-clock timeout, and maps
  # the exit status to a Result. The mapping follows Isolation.decode: exit 0 is
  # survived, exit 1 is killed, and any other exit is error (#292). When the clean
  # smoke run printed a Minitest or RSpec summary line, exit 1 is a kill only when
  # the output also shows a failing test, so a suite that crashed before its tests
  # ran is not a kill. The smoke check (below) guards a persistently broken
  # environment, and the score is disclosed as an upper bound.
  #
  # Child environment: bundler/gem env injected by Mutineer's Ruby is stripped, and
  # version-manager concrete version bins (e.g. `~/.rbenv/versions/3.4.9/bin`) are
  # removed from PATH so shims / `.ruby-version` can select the app's Ruby (#32).
  # PARALLEL_WORKERS and DISABLE_SPRING are set to 1 ({RailsRunEnv}), and so is
  # DISABLE_BOOTSNAP_COMPILE_CACHE ({child_env}).
  module ExternalBackend
    # Generous ceiling for the one-off smoke/calibration run (a cold app boot plus
    # the full suite). The per-mutant timeout is derived from how long this took.
    SMOKE_TIMEOUT = 900
    # Poll interval for the deadline wait loop. Independent of Isolation's loop —
    # this backend waits on an external process TREE, not an in-process fork.
    POLL = 0.02
    # Exit codes a shell or wrapper uses when the command could not run at all
    # (126: not executable, 127: not found). Scored `error`, never `killed`.
    CANNOT_RUN_CODES = [126, 127].freeze
    # The exit code Minitest, `bin/rails test` and RSpec use for a failing test.
    # Any other non-zero code is scored `error`, the same rule as Isolation.decode.
    FAILURE_CODE = 1

    # The end-of-run summary line of Minitest 5 and 6 ("N runs") and of
    # minitest-reporters ("N tests"). Captures the failure and error counts.
    MINITEST_SUMMARY = /\d+ (?:runs|tests), \d+ assertions, (\d+) failures, (\d+) errors/
    # The end-of-run summary line of RSpec ("N examples, N failures").
    # Captures the failure count.
    RSPEC_SUMMARY = /\d+ examples?, (\d+) failures?/
    # The line Minitest prints once every test file has loaded, before the first
    # test runs. Exit 1 after it with no summary line means code under test
    # called `exit 1` or `abort`, which the in-process backend also scores killed.
    MINITEST_RUNNING = "# Running:"
    # The line SimpleCov prints when its minimum_coverage gate fails the run.
    SIMPLECOV_GATE = /SimpleCov failed with exit \d+ due to a coverage related error/
    # The start of a line, after colour codes are removed: the start of the
    # text, or right after "\n" or "\r" (a progress bar that redraws a line).
    LINE_START = /(?:\A|(?<=[\n\r]))/
    # {MINITEST_SUMMARY} at the start of a line (#515).
    MINITEST_SUMMARY_AT_LINE_START = /#{LINE_START}#{MINITEST_SUMMARY}/
    # {RSPEC_SUMMARY} at the start of a line (#515).
    RSPEC_SUMMARY_AT_LINE_START = /#{LINE_START}#{RSPEC_SUMMARY}/
    # {MINITEST_RUNNING} at the start of a line (#515).
    MINITEST_RUNNING_AT_LINE_START = /#{LINE_START}#{Regexp.escape(MINITEST_RUNNING)}/
    # RSpec's note that a file raised outside any example, such as at load.
    RSPEC_OUTSIDE_ERROR = /errors? occurred outside of examples/
    # ANSI colour codes, removed before matching so a coloured summary still counts.
    ANSI_CODE = /\e\[[\d;]*m/
    # The seed line Minitest prints before every run ("Run options:"), or that
    # minitest-reporters prints ("Started with run options", or "# Running tests with run options"
    # for its DefaultReporter). Captures the seed.
    MINITEST_SEED = /^(?:Run options:|Started with run options|# Running tests with run options).*--seed (\d+)/
    # The seed line RSpec prints when it shuffles the tests. Captures the seed.
    RSPEC_SEED = /^Randomized with seed (\d+)/
    # A Minitest seed given on the command or in TESTOPTS (`SEED=N`, `--seed N`
    # `-s N` or `-sN`). Minitest prints its seed line for a fixed seed too, so
    # the line alone cannot tell.
    MINITEST_SEED_GIVEN = /\bSEED=|--seed\b|(?:\A|\s)-s(?![A-Za-z_])/
    # An RSpec order option that fixes the seed (`--seed N` or
    # `--order rand:N`). {random_order} matches it against the last
    # {RSPEC_ORDER_OPTION} RSpec reads. RSpec ignores SEED.
    RSPEC_SEED_GIVEN = /--seed\b|\brand(?:om)?:\d/
    # RSpec option files in the working directory. RSpec reads them before the
    # command and SPEC_OPTS, so an order option there counts unless a later
    # source gives another one (#522).
    RSPEC_OPTION_FILES = %w[.rspec .rspec-local].freeze
    # An RSpec order option: `--seed N`, `--order X` or `--order=X`. The last
    # one RSpec reads decides the order. Matched inside shell tokens too, so
    # `bash -c 'rspec --seed 7'` and `SPEC_OPTS="--seed 7"` count.
    RSPEC_ORDER_OPTION = /--(?:seed|order)(?:=|\s+)\S+/
    # An RSpec `--options FILE` or `-O FILE` on the command. RSpec then reads
    # that file instead of `.rspec` and `.rspec-local`. RSpec ignores it in
    # SPEC_OPTS.
    RSPEC_OPTIONS_FILE = /(?:\A|\s)(?:--options\b|-O)/
    # An RSpec example filter flag whose next shell token is a free-text
    # value (a description or a tag), not an option.
    RSPEC_FILTER_FLAG = /\A(?:-e|--example|-E|--example-matches|-t|--tag)\z/
    # An RSpec example filter with its free-text value in the same token.
    RSPEC_FILTER_VALUE = /\A--(?:example|example-matches|tag)=/

    # PATH entries that pin a concrete Ruby under a version manager (ahead of
    # shims). Optional trailing slash; normal bins are left alone.
    VERSION_BIN_PATH = %r{
      (?:
        /\.rbenv/versions/[^/]+/bin
        |/\.asdf/installs/ruby/[^/]+/bin
        |/\.rubies/[^/]+/bin
        |/rubies/[^/]+/bin
      )/?\z
    }x

    # Env keys Process.spawn must unset (nil value) so Mutineer's Ruby/bundler
    # context does not leak. Spawn merges env onto the parent; omitting a key
    # does NOT clear it.
    CLEAR_ENV_KEYS = %w[
      BUNDLER_VERSION RBENV_VERSION ASDF_RUBY_VERSION RBENV_DIR
    ].freeze

    # Turn a command template into an argv array (no shell → no eval, no
    # injection). The <tt>%{files}</tt> token expands IN PLACE to N separate argv
    # elements — one per path, unescaped — so a path containing a space stays a
    # single argument. It is not a space-joined string.
    #
    # @param command [String] the --test-command template (contains <tt>%{files}</tt>).
    # @param files [Array<String>] test file paths to substitute.
    # @return [Array<String>] argv.
    def self.build_argv(command, files)
      Shellwords.split(command).flat_map { |tok| tok == "%{files}" ? files : [tok] }
    end

    # Environment delta for the test-command child. Process.spawn merges this
    # onto the parent env: set a key to +nil+ to unset it. Scrubs Mutineer/bundler
    # injection and version-manager PATH pins so shims / `.ruby-version` can win.
    # Keeps other vars (e.g. `RAILS_ENV`) so setting them on the Mutineer command
    # still reaches the suite. Also sets +PARALLEL_WORKERS+, +DISABLE_SPRING+ and
    # +DISABLE_BOOTSNAP_COMPILE_CACHE+ to 1. A wrapper can change them again.
    # Bootsnap checks only that its variable is set, so only unsetting it turns
    # the cache back on. The Bootsnap pin is here, not in
    # {RailsRunEnv.pin_child!}: this backend rewrites each source file in place,
    # and Bootsnap keys its compile cache on path, size and whole-second mtime,
    # so a same-size mutant written in the same second can load the previous
    # mutant's cached code (#285). The daemon loads each mutant from a new file
    # and keeps the cache.
    #
    # @api private
    # @return [Hash{String => String, nil}] env for Process.spawn.
    def self.child_env
      env = {}
      cleared_pin = false
      ENV.each_key do |k|
        next unless clear_env_key?(k)

        env[k] = nil
        cleared_pin = true
      end
      path = ENV["PATH"].to_s.split(File::PATH_SEPARATOR)
      kept = path.reject { |p| p.match?(VERSION_BIN_PATH) }
      scrubbed_bin = kept.size != path.size
      # Only reorder PATH when we scrubbed a pin; otherwise leave the user's PATH alone.
      path = if cleared_pin || scrubbed_bin
               (version_manager_shim_dirs + kept).uniq
             else
               kept
             end
      env["PATH"] = path.join(File::PATH_SEPARATOR)
      RailsRunEnv.pin_child!(env, spring: true)
      env["DISABLE_BOOTSNAP_COMPILE_CACHE"] = "1"
      env
    end

    # True when the key must be unset in the child (bundler/gem/version-manager).
    #
    # @api private
    # @param key [String] environment variable name.
    # @return [Boolean]
    def self.clear_env_key?(key)
      key.start_with?("BUNDLE_", "RUBY", "GEM_") || CLEAR_ENV_KEYS.include?(key)
    end

    # Existing shim directories for rbenv / asdf (chruby uses PATH without shims).
    #
    # @api private
    # @return [Array<String>] absolute shim paths that exist.
    def self.version_manager_shim_dirs
      home = ENV["HOME"]
      return [] if home.nil? || home.empty?

      [
        File.join(home, ".rbenv", "shims"),
        File.join(home, ".asdf", "shims")
      ].select { |d| File.directory?(d) }
    end

    # Runs the command for ONE mutant against whatever is currently on disk (the
    # caller has already swapped the mutant in via FileSwap). Maps the outcome to a
    # Result. Uses {child_env} so version-manager PATH pins from Mutineer's Ruby do
    # not force the suite onto the wrong interpreter.
    #
    # @param command [String] the --test-command template.
    # @param files [Array<String>] test file paths.
    # @param timeout [Numeric] per-mutant wall-clock timeout in seconds.
    # @param verbose [Boolean] print the child's captured output on a non-pass.
    # @param check_summary [Boolean, :line] score exit 1 as killed only when the
    #   output has a summary line that reports a failing test (see
    #   {failure_reported?}). `true` matches a summary at any position, as in
    #   1.9.0. `:line` matches a summary and the `# Running:` line only at the
    #   start of a line (#515). The runner passes {summary_mode} of the clean
    #   smoke run.
    # @param clean_summaries [Integer] how many summary lines the clean smoke
    #   run printed ({summary_count}). After a SimpleCov gate, a passing run
    #   with fewer scores error, not survived (#516). 0 keeps the 1.9.0 rule.
    # @return [Mutineer::Result]
    def self.run(command, files, timeout:, verbose: false, check_summary: false, clean_summaries: 0)
      kind, code, output, = spawn_capture(command, files, timeout)
      case kind
      when :timeout
        # A timeout is the one non-pass we flag by default — a normal kill is also
        # a non-zero exit, so notifying on every non-zero would spam every kill.
        warn "[mutineer] test-command exceeded #{timeout}s and was killed (scored timeout)."
        warn Redaction.text(output) if verbose && !output.empty?
        Result.timeout
      else # :exited
        return Result.survived if code&.zero?
        # Signal death (nil exitstatus) is infrastructure, not a suite assertion
        # failure — match Isolation/daemon (error), do not inflate kill rate.
        if code.nil?
          warn Redaction.text(output) if verbose && !output.empty?
          return error_with_output("test-command terminated by signal", output)
        end

        warn Redaction.text(output) if verbose && !output.empty?
        # 126 (cannot execute) and 127 (command not found) come from a wrapper
        # such as `bundle exec` that could not start the suite: no test ran.
        return error_with_output("test-command could not start (exit #{code})", output) if CANNOT_RUN_CODES.include?(code)

        text = summary_text(output)
        line = check_summary == :line
        # SimpleCov's minimum_coverage gate replaced the exit code. Under
        # Minitest it runs in Minitest.after_run even after a failing test, so a
        # failing summary plus its message is still a kill. A passing summary
        # plus its message means no test caught the mutant: in process, the
        # fork exits before that hook, and the mutant survives. Keyed on
        # SimpleCov's own message, so code under test that calls `exit 2`
        # outside a running Minitest test still scores error (inside one, see
        # {exited_during_tests?}, #342 limit 8). A passing run survives only
        # when it printed at least as many summary lines as the clean run: with fewer,
        # the gate stopped a chain of suites, and a suite that did not run
        # could kill the mutant (#516). Estimate: below 1 in 100 --test-command
        # setups, unmeasured. Ceiling (#342 limits 2, 9, 10, tracked in #549):
        # with `SimpleCov.print_error_status = false` the gate prints nothing,
        # and its exit scores error too; a clean run with no summary line keeps
        # the 1.9.0 rule, and so does a gate that stops the plain first suite
        # of a chain whose second suite is prefixed. Interleaved parallel
        # output that moves a passing summary off the line start can turn a
        # correct survived into error.
        if text.match?(SIMPLECOV_GATE)
          return Result.killed if failure_reported?(text, line: line)
          # A failing test whose summary is off the line start is no proof of
          # a survivor: no verdict, with the same reason as on exit 1 (#515).
          return moved_summary_error(code, output, "failing") if line && failure_reported?(text)
          # A passing summary that is only off the line start: no survivor
          # proof either, and the reason says why.
          return moved_summary_error(code, output, "passing") if line && !summary_line?(text, line: true) && tests_passed?(text)

          if tests_passed?(text, line: line)
            printed = summary_count(text, line: line)
            return Result.survived if printed >= clean_summaries

            return error_with_output("test-command printed #{printed} summary #{printed == 1 ? 'line' : 'lines'} " \
                                     "where the clean run printed #{clean_summaries}, after a SimpleCov coverage " \
                                     "gate ended it; a suite that did not run could still kill this mutant " \
                                     "(turn the gate off for mutation runs)", output)
          end
        end

        unless code == FAILURE_CODE
          return error_with_output("test-command exited #{code} (only exit 1 counts as a kill; " \
                                   "check RSpec --failure-exit-code, a coverage gate, or your wrapper)", output)
        end

        if check_summary && !failure_reported?(text, line: line) && !exited_during_tests?(text, line: line)
          # A kill whose failing summary a wrapper or interleaved parallel
          # output moved off the line start lands here (#549). Estimate: below
          # 1 in 100 --test-command setups, unmeasured. The reason names it.
          return moved_summary_error(code, output, "failing") if line && failure_reported?(text)

          return error_with_output("test-command exited 1 but its output shows no failing test " \
                                   "(the suite or the mutant crashed before tests ran; --verbose shows the output)", output)
        end

        # "# Running:" starts a line, then only passing summary text away from
        # a line start: a real summary a wrapper moved, or a -v test name
        # before a stop. The output cannot tell, so no verdict, as in 1.9.0.
        if line && !failure_reported?(text) && summary_after_running?(text)
          return moved_summary_error(code, output, "passing")
        end

        Result.killed
      end
    end

    # An errored Result whose details end with the command's last non-blank
    # output line, redacted and cut like a child cause (#480). The output
    # alone is the cause a `--test-command` run can give.
    #
    # @api private
    # @param message [String] why the run scored error.
    # @param output [String] captured child stdout+stderr.
    # @return [Mutineer::Result]
    def self.error_with_output(message, output)
      # Redact before the split, so a password that spans lines is hidden whole.
      text = Redaction.text(summary_text(output).force_encoding(Encoding::UTF_8).scrub)
      last = text.lines("\n").map(&:strip).reject(&:empty?).last
      Result.error(last ? "#{message}; last output line: #{ChildCause.clip(last)}" : message)
    end

    # The errored Result for a run in `:line` mode whose failing or passing
    # summary is in its output, but only away from the start of a line (#515).
    #
    # @api private
    # @param code [Integer] the command's exit code.
    # @param output [String] captured child stdout+stderr.
    # @param kind [String] "failing" or "passing".
    # @return [Mutineer::Result]
    def self.moved_summary_error(code, output, kind)
      error_with_output("test-command exited #{code} and a #{kind} summary is in its output, but not at the " \
                        "start of a line, where the clean run printed its summary (a wrapper or a " \
                        "parallel runner moved it, or a test printed #{kind} summary-like text; " \
                        "--verbose shows the output)", output)
    end

    # The Minitest and RSpec summary patterns, at the start of a line when
    # +line+ is true, else at any position.
    #
    # @api private
    # @param line [Boolean]
    # @return [Array(Regexp, Regexp)] `[minitest, rspec]`.
    def self.summary_patterns(line)
      line ? [MINITEST_SUMMARY_AT_LINE_START, RSPEC_SUMMARY_AT_LINE_START] : [MINITEST_SUMMARY, RSPEC_SUMMARY]
    end

    # How a mutant run must match summary lines, from the clean run's output
    # (#515): `:line` when a summary line starts a line, `true` when summary
    # lines exist only at other positions (a wrapper that prefixes each line),
    # `false` when there is none. Real Minitest and RSpec reporters print the
    # summary at the start of a line, while summary-like text in a test name
    # (Minitest `-v`) or after a progress dot does not start one.
    #
    # @api private
    # @param text [String] output from {summary_text}.
    # @return [:line, Boolean]
    def self.summary_mode(text)
      return :line if summary_line?(text, line: true)

      summary_line?(text)
    end

    # The number of Minitest and RSpec summary lines in the text (#516).
    #
    # @api private
    # @param text [String] output from {summary_text}.
    # @param line [Boolean] count a summary only at the start of a line.
    # @return [Integer]
    def self.summary_count(text, line: false)
      summary_patterns(line).sum { |pattern| text.scan(pattern).size }
    end

    # True when the text has a Minitest or RSpec summary line.
    #
    # @api private
    # @param text [String] output from {summary_text}.
    # @param line [Boolean] count a summary only at the start of a line.
    # @return [Boolean]
    def self.summary_line?(text, line: false)
      summary_patterns(line).any? { |pattern| text.match?(pattern) }
    end

    # True when a summary line reports a failing test: a Minitest failure or
    # error, or an RSpec failure. An RSpec error outside examples alone (a spec
    # file that raised while loading) is not one, as in TestRunners::RSpec.
    # Any matching line counts, so a wrapper that runs two suites still kills.
    # With +line+, a summary counts only at the start of a line, so a fake
    # summary in a Minitest `-v` test name, after a progress dot, or in an
    # indented RSpec example name no longer reads as a failing test (#342
    # limit 4, #515). Ceiling (#549): summary-like text that a test prints at
    # a line start still fools it, such as the first output after
    # `# Running:` or at the start of RSpec output, even with no newline; so
    # does an RSpec top-level group with such a name; and a wrapper that
    # prefixes every line keeps matching at any
    # position (mode `true`), so limit 4 stays whole there. Estimate: the fix
    # changes a verdict in far below 1 project in 1,000.
    #
    # @api private
    # @param text [String] output from {summary_text}.
    # @param line [Boolean] count a summary only at the start of a line.
    # @return [Boolean]
    def self.failure_reported?(text, line: false)
      minitest, rspec = summary_patterns(line)
      text.scan(minitest).any? { |failures, errors| (failures.to_i + errors.to_i).positive? } ||
        text.scan(rspec).any? { |(failures)| failures.to_i.positive? }
    end

    # True when Minitest started its tests and the process then ended with no
    # summary line after that start: code under test called `exit 1` or
    # `abort` mid-run. Only the last start counts, so a wrapper whose earlier
    # suite printed a summary still kills. A load crash ends before Minitest
    # prints {MINITEST_RUNNING}, so it stays false.
    # Only the default Minitest reporter prints that line: under RSpec or
    # minitest-reporters, such an exit scores error, not killed. With +line+,
    # the start line and the summary count only at the start of a line (#515).
    # Accepted (#342 limits 3 and 8, tracked in #549): an exception that
    # escapes Minitest.run itself (a reporter plugin bug) also reads as a
    # kill here, where the in-process backend scores error. Its output and
    # status are the same as code under test that runs
    # `warn e.full_message; exit 1` in a test, a real kill. Minitest's
    # `autorun` ends the process with status 1 after any `exit` during a
    # test, and prints the same output, so `exit 0` and `exit 2` read as a
    # kill too.
    #
    # @api private
    # @param text [String] output from {summary_text}.
    # @param line [Boolean] count the start line and a summary only at the start of a line.
    # @return [Boolean]
    def self.exited_during_tests?(text, line: false)
      running_at = text.rindex(line ? MINITEST_RUNNING_AT_LINE_START : MINITEST_RUNNING)
      return false unless running_at

      summary_at = summary_patterns(line).filter_map { |pattern| text.rindex(pattern) }.max
      summary_at.nil? || summary_at < running_at
    end

    # True when a Minitest or RSpec summary, at any position, follows the
    # last `# Running:` line that starts a line (#515).
    #
    # @api private
    # @param text [String] output from {summary_text}.
    # @return [Boolean]
    def self.summary_after_running?(text)
      running_at = text.rindex(MINITEST_RUNNING_AT_LINE_START)
      return false unless running_at

      summary_patterns(false).any? { |pattern| (at = text.rindex(pattern)) && at > running_at }
    end

    # True when a recognized summary line is present and none shows a failing
    # test or an RSpec error outside examples. With no recognized summary line
    # (a JUnit or custom reporter), it is false, so a SimpleCov gate exit there
    # scores error rather than a survivor the output cannot prove.
    #
    # @api private
    # @param text [String] output from {summary_text}.
    # @param line [Boolean] count a summary only at the start of a line.
    # @return [Boolean]
    def self.tests_passed?(text, line: false)
      summary_line?(text, line: line) && !failure_reported?(text, line: line) && !text.match?(RSPEC_OUTSIDE_ERROR)
    end

    # The output as binary with ANSI colour codes removed. Binary, so bytes that
    # are invalid in the default encoding (an unset locale) cannot raise.
    # Computed once per run and passed to the predicates above.
    #
    # @api private
    # @param output [String] captured child stdout+stderr.
    # @return [String]
    def self.summary_text(output)
      output.b.gsub(ANSI_CODE, "")
    end

    # The runner and seed of a random test order the output shows, or nil.
    # Nil also when Mutineer sees a fixed seed: for Minitest, SEED, TESTOPTS
    # or the command sets one. For RSpec, the last order option decides, read
    # in RSpec's order: `.rspec`, `.rspec-local`, the command, SPEC_OPTS
    # (#522). The order is fixed only when that option is `--seed N` or
    # `--order rand:N`. With `--options FILE` or `-O FILE` in the command,
    # RSpec skips the two files, and so does this check. RSpec
    # `--order defined` prints no seed line. Each runner is checked on its
    # own, so a seeded Minitest suite does not hide an unseeded RSpec suite
    # that the same command runs. Mutineer only warns: it cannot know the
    # seed flag of an arbitrary command, so it sets no seed. Ceiling (#549):
    # a seed set in a wrapper script, `~/.rspec`, `config.seed`, Minitest's
    # `test_order`, the file that `--options` names, or an inactive ERB
    # branch of an option file is not seen, so the warning still prints. A
    # seed-like argument meant for a wrapper hides it. A `cd` inside a
    # wrapper makes RSpec read another `.rspec` than this check does.
    #
    # @api private
    # @param command [String] the --test-command template.
    # @param text [String] output from {summary_text}.
    # @return [Array(Symbol, String), nil] `[:minitest | :rspec, seed]`.
    def self.random_order(command, text)
      minitest = text[MINITEST_SEED, 1]
      if minitest && ENV["SEED"].to_s.empty? &&
         [command, ENV["TESTOPTS"]].none? { |s| s.to_s.match?(MINITEST_SEED_GIVEN) }
        return [:minitest, minitest]
      end

      rspec = text[RSPEC_SEED, 1]
      return unless rspec

      files = rspec_tokens([command]).any? { |t| t.match?(RSPEC_OPTIONS_FILE) } ? [] : rspec_option_files
      last = rspec_tokens([*files.flat_map(&:lines), command, ENV["SPEC_OPTS"]]).join("\n").scan(RSPEC_ORDER_OPTION).last
      [:rspec, rspec] unless last&.match?(RSPEC_SEED_GIVEN)
    end

    # The shell tokens of the sources, in order, without the free-text value
    # of an RSpec example filter, so `--example 'handles --order rand'` is
    # not read as an option (#522). A token that holds a nested command, such
    # as `bash -c 'rspec --seed 7'`, stays whole and is still scanned.
    #
    # @api private
    # @param sources [Array<String, nil>] a command, SPEC_OPTS, or option file lines.
    # @return [Array<String>] binary tokens.
    def self.rspec_tokens(sources)
      tokens = sources.flat_map { |s| option_tokens(s) }
      tokens.reject.with_index do |t, i|
        t.match?(RSPEC_FILTER_VALUE) || (i.positive? && tokens[i - 1].match?(RSPEC_FILTER_FLAG))
      end
    end

    # The shell tokens of a command or option text, as binary strings, so
    # text in any encoding splits without raising. Text with an unmatched
    # quote, which the shell would reject, splits at whitespace instead.
    #
    # @api private
    # @param text [String, nil]
    # @return [Array<String>]
    def self.option_tokens(text)
      Shellwords.split(text.to_s.b)
    rescue ArgumentError
      text.to_s.b.split
    end

    # The text of the RSpec option files that exist in the working directory,
    # without comment lines (RSpec ignores a line that starts with `#`).
    #
    # @api private
    # @return [Array<String>]
    def self.rspec_option_files
      RSPEC_OPTION_FILES.filter_map do |f|
        File.readlines(f, encoding: "BINARY").grep_v(/\A\s*#/).join if File.file?(f)
      rescue SystemCallError
        nil # unreadable: the check only decides on a warning, so count it as no seed
      end
    end

    # Pre-flight: run the command once against the UNMUTATED tree. Green (exit 0)
    # returns the elapsed seconds (used to calibrate the per-mutant timeout),
    # the {summary_mode} of the output (passed to {run} as `check_summary`),
    # the runner and seed of a random test order (see {random_order}), and
    # the {summary_count} in that mode (passed to {run} as `clean_summaries`);
    # anything else raises SmokeCheckError so the run aborts before scoring.
    #
    # @param command [String] the --test-command template.
    # @param files [Array<String>] test file paths.
    # @param timeout [Numeric] ceiling for the calibration run.
    # @return [Array(Float, (:line, Boolean), (Array(Symbol, String), nil), Integer)]
    #   `[elapsed_seconds, summary_mode, random_order, summary_count]`.
    # @raise [Mutineer::SmokeCheckError] when the clean suite is not green.
    def self.smoke_check!(command, files, timeout: SMOKE_TIMEOUT)
      kind, code, output, elapsed = spawn_capture(command, files, timeout)
      if kind == :exited && code&.zero?
        text = summary_text(output)
        mode = summary_mode(text)
        return [elapsed, mode, random_order(command, text), summary_count(text, line: mode == :line)]
      end

      reason =
        if kind == :timeout then "did not finish within #{timeout}s"
        elsif code.nil?      then "was terminated by a signal"
        else                      "exited #{code}"
        end
      detail = output.empty? ? "" : "\n--- last output ---\n#{tail(output)}"
      hint = ruby_version_mismatch_hint(output)
      raise SmokeCheckError,
            "the test command #{reason} against the UNMUTATED source — " \
            "#{hint || generic_env_hint}.#{detail}"
    end

    # Generic smoke-failure framing when no Ruby-version mismatch is detected.
    #
    # @api private
    # @return [String]
    def self.generic_env_hint
      "the unmutated suite is not green (failing tests, or a broken environment: " \
        "DB, RAILS_ENV, migrations) — fix that before scoring"
    end

    # Targeted hint when Bundler reports a RubyVersionMismatch (common under
    # rbenv/asdf/chruby when Mutineer's version bin sits ahead of shims on PATH).
    #
    # @api private
    # @param output [String] captured child stdout+stderr.
    # @return [String, nil] hint text, or nil when not a version mismatch.
    def self.ruby_version_mismatch_hint(output)
      return nil if output.nil? || output.empty?
      return nil unless output.match?(/RubyVersionMismatch|Your Ruby version is .* but your Gemfile specified/i)

      ran = output[/Your Ruby version is ([0-9.]+)/i, 1]
      want = output[/Gemfile specified ([0-9.]+)/i, 1]
      parts = +"Detected a Ruby version mismatch"
      parts << ": the test command ran under #{ran}" if ran
      parts << " but the app expects #{want}" if want
      parts << ". Mutineer already scrubbed version-manager bins and RBENV_VERSION/" \
               "ASDF_RUBY_VERSION from the child env; the suite still picked the wrong " \
               "Ruby. Use a wrapper that re-selects the app Ruby and ensure " \
               ".ruby-version / .tool-versions is present " \
               "(see https://github.com/davidteren/mutineer/blob/main/docs/rails-setup.md#apps-on-ruby--34, section Under a version manager)"
      parts
    end

    # RUBYOPT for a `--test-command` child: the copier file alone. The tool's
    # own RUBYOPT (`-rbundler/setup` under `bundle exec`) stays out, as
    # {child_env} clears every `RUBY*` key so the suite picks its own Ruby and
    # gems. Empty when the copier file cannot be named without whitespace.
    #
    # @api private
    # @param dir [String] the directory that holds command_redact.rb.
    # @return [String]
    def self.command_rubyopt(dir = __dir__)
      path = command_redact_file(dir)
      path ? "-r#{path}" : ""
    end

    # Path of command_redact.rb that RUBYOPT can carry. Ruby splits RUBYOPT at
    # whitespace and has no quoting or escape, so a path with a space (a home
    # directory named "Jane Doe") makes every Ruby child stop with "invalid
    # switch in RUBYOPT". Such a path is reached through a symlink in a
    # temporary directory, removed when this process exits. `require_relative`
    # in the file resolves the real path, so the rest of the copier loads.
    #
    # @api private
    # @param dir [String] the directory that holds command_redact.rb.
    # @return [String, nil] nil when the temporary directory name has whitespace too.
    def self.command_redact_file(dir)
      path = File.expand_path("command_redact.rb", dir)
      return path unless path.match?(/\s/)

      COMMAND_REDACT_LINKS[dir] ||= begin
        tmp = Dir.mktmpdir("mutineer-redact")
        at_exit { FileUtils.remove_entry(tmp, true) }
        link = File.join(tmp, "command_redact.rb")
        File.symlink(path, link)
        link
      end
      link = COMMAND_REDACT_LINKS[dir]
      link.match?(/\s/) ? nil : link
    end

    # Symlinks {command_redact_file} made, by source directory.
    COMMAND_REDACT_LINKS = {} # rubocop:disable Style/MutableConstant

    # Spawns the command to a captured combined-output tempfile, enforces a
    # wall-clock timeout (SIGKILL past the deadline), and returns
    # [kind, exit_code, output, elapsed]. Mirrors Isolation's single-waiter loop:
    # we are the only caller of waitpid on this pid, so the kill can never hit a
    # reaped/recycled pid.
    #
    # @api private
    def self.spawn_capture(command, files, timeout)
      argv = build_argv(command, files)
      # Unreachable in practice (validate_test_command! guarantees a non-empty
      # command with %{files}); a neutral ArgumentError, not the smoke-specific
      # SmokeCheckError, since this is not a smoke-check failure.
      raise ArgumentError, "--test-command produced an empty command" if argv.empty?

      out = Tempfile.create("mutineer_ext")
      start = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      # `pgroup: true` puts the child in its OWN process group so a timeout can
      # kill the whole tree (`bundle exec rails test` forks parallel workers;
      # spring/bundler add more) — killing only the leader would orphan workers
      # that keep holding the shared DB, corrupting later serial mutants. The
      # explicit [program, argv0] form guarantees the no-shell exec path even for a
      # degenerate single-element argv (Process.spawn(*argv) would route a lone
      # metachar-bearing string through /bin/sh, breaking the argv-only invariant).
      # RUBYOPT loads the copier in each Ruby process this command starts, so a
      # password that process assigns is hidden before the bytes are captured
      # (#457). A program that is not Ruby ignores RUBYOPT.
      pid = Process.spawn(child_env.merge("RUBYOPT" => command_rubyopt), [argv.first, argv.first], *argv[1..],
                          out: out, err: %i[child out], pgroup: true)
      kind, code = wait_with_timeout(pid, timeout)
      elapsed = Process.clock_gettime(Process::CLOCK_MONOTONIC) - start
      out.rewind
      # Test output is arbitrary bytes. Read it as UTF-8 whatever the locale (#303).
      # Each invalid byte becomes `\xNN`, as in Reporter#printable, so the
      # smoke-failure checks can match on the text and nothing is lost.
      output = out.read.force_encoding(Encoding::UTF_8)
                  .scrub { |bytes| bytes.unpack("C*").map { |b| format("\\x%02X", b) }.join }
      [kind, code, output, elapsed]
    ensure
      if out
        out.close
        File.unlink(out.path) rescue nil # rubocop:disable Style/RescueModifier
      end
    end

    # Waits for the spawned pid, SIGKILLing its process group past the deadline.
    # Single-waiter deadline loop (mirrors Isolation), so the kill can never hit a
    # reaped/recycled pid.
    #
    # @api private
    # @param pid [Integer] the spawned child pid.
    # @param timeout [Numeric] wall-clock deadline in seconds.
    # @return [Array(Symbol, Integer, nil)] `[:exited, code]` or `[:timeout, nil]`.
    def self.wait_with_timeout(pid, timeout)
      deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + timeout
      loop do
        reaped, status = Process.waitpid2(pid, Process::WNOHANG)
        return [:exited, status.exitstatus] if reaped

        if Process.clock_gettime(Process::CLOCK_MONOTONIC) >= deadline
          # Kill the whole process GROUP (negative pid) so forked test workers die
          # with the leader; fall back to the leader alone if the group is already
          # gone. The child led its group (pgroup: true at spawn).
          begin
            Process.kill(:KILL, -pid)
          rescue Errno::ESRCH, Errno::EPERM
            Process.kill(:KILL, pid) rescue nil # rubocop:disable Style/RescueModifier
          end
          begin
            _reaped, status = Process.waitpid2(pid)
            # Finished cleanly between poll and kill — honor real exit code.
            return [:exited, status.exitstatus] if status && status.exited? && !status.signaled?
          rescue Errno::ECHILD
            # already reaped
          end
          return [:timeout, nil]
        end
        sleep POLL
      end
    end

    # Last ~40 lines of captured output, for a smoke-failure message.
    #
    # @api private
    def self.tail(output, lines = 40)
      output.lines.last(lines).join
    end
  end
end
