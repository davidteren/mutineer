# frozen_string_literal: true

module Mutineer
  # Immutable outcome of running one mutant. Ten distinct states:
  #   killed       - a test failed/errored, so the mutation was caught.
  #   survived     - every test passed, so the mutation went undetected.
  #   error        - the child crashed (unhandled exception): exit status 2.
  #   timeout      - the parent SIGKILLed a child that overran its wall clock.
  #   skipped      - the mutated source failed to re-parse (invalid); no fork.
  #   no_coverage  - no test exercises the mutated line; not run, not scored.
  #                  Also a mutant on a later line of a multi-line statement,
  #                  in code that runs only sometimes, that the statement's
  #                  tests ran but did not kill (#254): they may not reach it.
  #   uncapturable - the line's would-be covering test errored during capture,
  #                  so coverage was lost. Excluded from the denominator exactly
  #                  like no_coverage, but reported separately: it signals a
  #                  broken harness (a test that failed to run), not a genuine
  #                  coverage gap.
  #   unplaceable  - the strategy cannot load the mutant where the tests call
  #                  it, so it is not run. Under `--strategy redefine` the
  #                  method belongs to a class or module that cannot be named
  #                  statically (for example each class that includes a
  #                  concern). Under either strategy the method is in a
  #                  concern's `included` or `prepended` block, which does not
  #                  run again in a class that already includes it (#256).
  #                  Excluded from the denominator and, unlike uncapturable,
  #                  from the no-verdict gate: nothing is broken.
  #                  `--test-command` runs these mutants.
  #   ran_at_load  - the mutated line ran while the app booted or its class
  #                  loaded. That run happened before the mutant was applied,
  #                  so a test can check a value the original code computed.
  #                  A survivor on such a line, and a line that ran only at
  #                  load, get this status; a kill stays killed. Excluded from
  #                  the denominator and from the no-verdict gate, like
  #                  unplaceable. `--test-command` verifies these mutants.
  #                  `tested_at_load` is true when the mutant's covering tests
  #                  ran and passed (a survivor, JobPlan.load_verdict), so it
  #                  may hide a test gap (#286); false when no test ran it.
  #   ignored      - a known-equivalent mutant the user suppressed, via an
  #                  inline `# mutineer:disable-line` comment or a
  #                  `.mutineer.yml` `ignore:` id. A pre-fork classification
  #                  (never run); excluded from the denominator so a strong
  #                  file can reach 100%.
  #
  # `error` and `skipped` are deliberately distinct: skipped is a pre-fork
  # validity failure (counted separately by the reporter), error is a runtime
  # crash. Never conflate them via `details` string parsing. `uncapturable` and
  # `unplaceable` are pre-fork results, and `no_coverage` and `ran_at_load` are
  # pre-fork or a reclassified result (JobPlan.selection_verdict,
  # JobPlan.load_verdict): all excluded from the score denominator.
  #
  # `subject`, `mutation`, and `id` are nil when the Result is built by
  # Isolation/Runner (which only know the outcome); the orchestrator attaches
  # them afterwards via `result.with(subject:, mutation:, id:)` so the Reporter
  # can render survivor diffs and emit the id. `id` is the content-based
  # MutantId (it includes the project-relative file path).
  #
  # `kills` is nil except in a `--matrix` run, where a mutant that was forked
  # carries the {Kills} its child reported. It annotates the verdict and never
  # decides it.
  #
  # A Result crosses a process boundary only through WorkerPool's Marshal pipe,
  # from a fork back to the process that forked it, so both ends always run the
  # same code. Nothing persists a marshaled Result (reports, baselines and the
  # coverage cache are JSON), so a new field needs no Marshal compatibility.
  Result = Data.define(:status, :details, :subject, :mutation, :id, :kills, :reason, :tested_at_load) do
    # Every field but `status` defaults to nil, and `tested_at_load` to false.
    # `reason` is the text a user gave for an ignored mutant, from an inline
    # marker or an `ignore:` mapping.
    #
    # @param status [Symbol] the outcome.
    # @param details [String, nil] error or skip details.
    # @param subject [Mutineer::Subject, nil] the mutated subject.
    # @param mutation [Mutineer::Mutation, nil] the mutation.
    # @param id [String, nil] the stable mutant id.
    # @param kills [Mutineer::Kills, nil] the matrix row of a `--matrix` run.
    # @param reason [String, nil] why an ignored mutant was suppressed.
    # @param tested_at_load [Boolean] a ran_at_load mutant whose covering tests ran and passed.
    def initialize(status:, details: nil, subject: nil, mutation: nil, id: nil, kills: nil, reason: nil,
                   tested_at_load: false)
      super
    end

    # Builds a killed result.
    #
    # @return [Mutineer::Result] killed result.
    def self.killed = new(status: :killed, details: nil, subject: nil, mutation: nil, id: nil)

    # Builds a survived result.
    #
    # @return [Mutineer::Result] survived result.
    def self.survived = new(status: :survived, details: nil, subject: nil, mutation: nil, id: nil)

    # Builds an error result.
    #
    # @param details [String, nil] error details.
    # @return [Mutineer::Result] error result.
    def self.error(details = nil) = new(status: :error, details: details, subject: nil, mutation: nil, id: nil)

    # Builds a timeout result.
    #
    # @return [Mutineer::Result] timeout result.
    def self.timeout = new(status: :timeout, details: nil, subject: nil, mutation: nil, id: nil)

    # Builds a skipped result.
    #
    # @param details [String, nil] skip details.
    # @return [Mutineer::Result] skipped result.
    def self.skipped(details = nil) = new(status: :skipped, details: details, subject: nil, mutation: nil, id: nil)

    # Builds a no_coverage result.
    #
    # @return [Mutineer::Result] no-coverage result.
    def self.no_coverage = new(status: :no_coverage, details: nil, subject: nil, mutation: nil, id: nil)

    # Builds an uncapturable result.
    #
    # @return [Mutineer::Result] uncapturable result.
    def self.uncapturable = new(status: :uncapturable, details: nil, subject: nil, mutation: nil, id: nil)

    # Builds an unplaceable result.
    #
    # @return [Mutineer::Result] unplaceable result.
    def self.unplaceable = new(status: :unplaceable, details: nil, subject: nil, mutation: nil, id: nil)

    # Builds a ran_at_load result.
    #
    # @return [Mutineer::Result] ran-at-load result.
    def self.ran_at_load = new(status: :ran_at_load, details: nil, subject: nil, mutation: nil, id: nil)

    # Builds an ignored result.
    #
    # @return [Mutineer::Result] ignored result.
    def self.ignored = new(status: :ignored, details: nil, subject: nil, mutation: nil, id: nil)

    # @return [Boolean] true when the status is killed.
    def killed?       = status == :killed
    # @return [Boolean] true when the status is survived.
    def survived?     = status == :survived
    # @return [Boolean] true when the status is error.
    def error?        = status == :error
    # @return [Boolean] true when the status is timeout.
    def timeout?      = status == :timeout
    # @return [Boolean] true when the status is skipped.
    def skipped?      = status == :skipped
    # @return [Boolean] true when the status is no_coverage.
    def no_coverage?  = status == :no_coverage
    # @return [Boolean] true when the status is uncapturable.
    def uncapturable? = status == :uncapturable
    # @return [Boolean] true when the status is unplaceable.
    def unplaceable?  = status == :unplaceable
    # @return [Boolean] true when the status is ran_at_load.
    def ran_at_load?  = status == :ran_at_load
    # @return [Boolean] true when the status is ignored.
    def ignored?      = status == :ignored
    # @return [Boolean] true for a ran_at_load mutant whose covering tests ran and passed.
    def tested_at_load? = tested_at_load == true
  end

  # One mutant's row of the kill matrix (`--matrix`): which tests killed it and
  # which ran against it. A test is a `[file, name, id]` triple: the
  # project-relative file that defines it, its name (`CalculatorTest#test_add`,
  # or an RSpec example's full description), and an id that tells apart tests
  # sharing a file and name (an RSpec example id; the name again for Minitest).
  # File and id identify a test; the name is display data that a mutant can
  # change. Both lists are sorted and unique, and `ran` includes the killers.
  #
  # `complete` is true when the child ran its whole suite and reported it
  # cleanly (see Isolation.finish). It is false when the child timed out,
  # errored or exited the process early, when the recorder never armed, when
  # its lines arrived out of order, when Minitest returned after an Interrupt
  # with tests unseen, or when the row does not agree with the verdict.
  Kills = Data.define(:killed_by, :ran, :complete)

  # Aggregates a flat list of Results into counts, the mutation score, and the
  # surviving-mutant list. The score denominator is killed + survived ONLY:
  # no-coverage, uncapturable, unplaceable, ran-at-load, skipped (invalid), errored, timeout, and ignored
  # (equivalent-mutant suppression) are each excluded and surfaced separately,
  # so suppressing every survivor reaches 100%. An empty denominator yields a
  # nil score (rendered "N/A"), never 0.0, distinguishing "no testable mutants"
  # from "0% killed".
  class AggregateResult
    # Share of attempted mutants that may produce no verdict before a gate
    # (`--threshold` or `--baseline`) stops trusting the run. A handful of flaky
    # mutants in a large run is noise; a mostly-broken run is not a score.
    # Deliberately not a flag: no one has needed a different number yet.
    BROKEN_SHARE_LIMIT = 0.10

    # A share alone gives a small run no tolerance at all: on a `--since` PR that
    # yields 8 mutants, one timeout is 12.5%. README recommends exactly that
    # workflow, so one bad mutant never fails the share rule on its own, at any
    # size. The nil-score rule has no floor: with nothing scored, one broken
    # mutant is enough (see #broken_nil_score?).
    BROKEN_FLOOR = 1

    attr_reader :results

    # Builds an aggregate from results.
    #
    # @param results [Array<Mutineer::Result>] classified results.
    def initialize(results)
      @results = results
      @by_status = results.group_by(&:status)
    end

    # @return [Integer] killed count.
    def killed_count          = count(:killed)
    # @return [Integer] survived count.
    def survived_count        = count(:survived)
    # @return [Integer] no-coverage count.
    def no_coverage_count     = count(:no_coverage)
    # @return [Integer] uncapturable count.
    def uncapturable_count    = count(:uncapturable)
    # @return [Integer] unplaceable count.
    def unplaceable_count     = count(:unplaceable)
    # @return [Integer] ran-at-load count.
    def ran_at_load_count     = count(:ran_at_load)
    # @return [Integer] ran-at-load mutants whose covering tests ran and passed (#286).
    def ran_at_load_tested_count = (@by_status[:ran_at_load] || []).count(&:tested_at_load?)
    # @return [Integer] skipped-invalid count.
    def skipped_invalid_count = count(:skipped)
    # @return [Integer] errored count.
    def errored_count         = count(:error)
    # @return [Integer] timeout count.
    def timeout_count         = count(:timeout)
    # @return [Integer] ignored count.
    def ignored_count         = count(:ignored)

    # Every generated, classified mutation. NOT the score denominator.
    #
    # @return [Integer] total result count.
    def total = @results.size

    # The score denominator (also shown to the reader).
    #
    # @return [Integer] killed plus survived.
    def covered_count = killed_count + survived_count

    # Computes the mutation score.
    #
    # @return [Float, nil] score percentage or nil when nothing was testable.
    def mutation_score
      return nil if covered_count.zero?

      (killed_count.to_f / covered_count * 100).round(1)
    end

    # Mutants that were attempted and produced no verdict, whatever the reason.
    #
    # @return [Integer] errored + timed out + uncapturable.
    def no_verdict_count = errored_count + timeout_count + uncapturable_count

    # Mutants that were actually run. Deliberately not `total`: no_coverage,
    # skipped-invalid and ignored mutants are not counted (a #254 no_coverage
    # mutant ran its statement's tests but is not a verdict), so counting them
    # would dilute the share and let a broken run slip under the limit.
    #
    # skipped-invalid is excluded from both sides: it means a mutant did not
    # re-parse and was correctly never run, which is a validity outcome rather
    # than a broken harness. Cost: an overwhelmingly-skipped run still scores on
    # what little ran; that is our operator misbehaving and wants its own signal.
    #
    # @return [Integer] killed + survived + no-verdict.
    def attempted_count = killed_count + survived_count + no_verdict_count

    # True when nothing could be scored and something broke: the score is nil
    # and some mutant errored, timed out or was uncapturable. A nil score from
    # pure no_coverage / ignored / an empty run is not broken.
    #
    # @return [Boolean]
    def broken_nil_score? = mutation_score.nil? && total.positive? && no_verdict_count.positive?

    # Mutants that were attempted but produced no verdict, over everything
    # attempted. Above the limit the score describes too small a slice of the run
    # to gate on. A few flaky mutants in a large run stay under it.
    #
    # @return [Boolean] true when too much of the run failed to produce a verdict.
    def broken_share_exceeded?
      attempted = attempted_count
      attempted.positive? && no_verdict_count > BROKEN_FLOOR &&
        no_verdict_count > attempted * BROKEN_SHARE_LIMIT
    end

    # The completeness rule (#78) that both `--threshold` and `--baseline`
    # gate on: the run cannot be trusted when nothing could be scored and
    # something broke, or when too much of it produced no verdict.
    #
    # @return [Boolean] true when the run is incomplete.
    def incomplete? = broken_nil_score? || broken_share_exceeded?

    # Returns the surviving mutants.
    #
    # @return [Array<Mutineer::Result>] surviving results.
    def surviving_mutants = @results.select(&:survived?)

    # Groups results by source file so the Reporter (per-source breakdown) and
    # baseline diff can reuse the same aggregate math.
    #
    # @return [Hash<String, Mutineer::AggregateResult>] source-file groups.
    def by_source
      @results.select { |r| r.subject }
              .group_by { |r| r.subject.file }
              .transform_values { |rs| AggregateResult.new(rs) }
    end

    private

    # Counts results for a status.
    #
    # @param status [Symbol] result status.
    # @return [Integer] count for that status.
    def count(status) = (@by_status[status] || []).size
  end
end
