# frozen_string_literal: true

module Mutineer
  # Immutable outcome of running one mutant. Seven distinct states:
  #   killed       — a test failed/errored, so the mutation was caught.
  #   survived     — every test passed, so the mutation went undetected.
  #   error        — the child crashed (unhandled exception): exit status 2.
  #   timeout      — the parent SIGKILLed a child that overran its wall clock.
  #   skipped      — the mutated source failed to re-parse (invalid); no fork.
  #   no_coverage  — no test exercises the mutated line; not run, not scored.
  #   uncapturable — the line's would-be covering test errored during capture
  #                  (#9), so coverage was lost. Excluded from the
  #                  denominator exactly like no_coverage, but reported
  #                  separately: it signals a broken harness (a test that
  #                  failed to run), not a genuine coverage gap.
  #   ignored      — a known-equivalent mutant the user suppressed (#10), via
  #                  an inline `# mutineer:disable-line` comment or a
  #                  `.mutineer.yml` `ignore:` id. A pre-fork classification
  #                  (never run); excluded from the denominator so a strong
  #                  file can reach 100%.
  #
  # `error` and `skipped` are deliberately distinct: skipped is a pre-fork
  # validity failure (counted separately by the reporter), error is a runtime
  # crash. Never conflate them via `details` string parsing. `no_coverage` and
  # `uncapturable` are pre-fork selection results (M3/#9): both excluded from
  # the score denominator.
  #
  # `subject`, `mutation`, and `id` are nil when the Result is built by
  # Isolation/Runner (which only know the outcome); the orchestrator attaches
  # them afterwards via `result.with(subject:, mutation:, id:)` so the Reporter
  # can render survivor diffs and emit the stable id. `id` is the content-based
  # MutantId (#10).
  Result = Data.define(:status, :details, :subject, :mutation, :id) do
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
    # @return [Boolean] true when the status is ignored.
    def ignored?      = status == :ignored

  end

  # Aggregates a flat list of Results into counts, the mutation score, and the
  # surviving-mutant list. The score denominator is killed + survived ONLY
  # (KTD-4): no-coverage, uncapturable, skipped (invalid), errored, timeout,
  # and ignored (#10 equivalent-mutant suppression) are each excluded and
  # surfaced separately — so suppressing every survivor reaches 100%. An empty
  # denominator yields a nil score (rendered "N/A"), never 0.0 —
  # distinguishing "no testable mutants" from "0% killed".
  class AggregateResult
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

    # Returns the surviving mutants.
    #
    # @return [Array<Mutineer::Result>] surviving results.
    def surviving_mutants = @results.select(&:survived?)

    # #11: split into { source_file => AggregateResult } so the Reporter
    # (per-source breakdown) and #13 (per-source roll-up / baseline diff) can
    # reuse the same aggregate math.
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
