# frozen_string_literal: true

module Mutineer
  # Immutable outcome of running one mutant. Six distinct states:
  #   killed      — a test failed/errored, so the mutation was caught.
  #   survived    — every test passed, so the mutation went undetected.
  #   error       — the child crashed (unhandled exception): exit status 2.
  #   timeout     — the parent SIGKILLed a child that overran its wall clock.
  #   skipped     — the mutated source failed to re-parse (invalid); no fork.
  #   no_coverage — no test exercises the mutated line; not run, not scored.
  #
  # `error` and `skipped` are deliberately distinct: skipped is a pre-fork
  # validity failure (counted separately by the reporter), error is a runtime
  # crash. Never conflate them via `details` string parsing. `no_coverage` is a
  # pre-fork selection result (M3): excluded from the score denominator.
  #
  # `subject` and `mutation` are nil when the Result is built by Isolation/Runner
  # (which only know the outcome); the orchestrator attaches them afterwards via
  # `result.with(subject:, mutation:)` so the Reporter can render survivor diffs.
  Result = Data.define(:status, :details, :subject, :mutation) do
    def self.killed               = new(status: :killed, details: nil, subject: nil, mutation: nil)
    def self.survived             = new(status: :survived, details: nil, subject: nil, mutation: nil)
    def self.error(details = nil) = new(status: :error, details: details, subject: nil, mutation: nil)
    def self.timeout              = new(status: :timeout, details: nil, subject: nil, mutation: nil)
    def self.skipped(details = nil) = new(status: :skipped, details: details, subject: nil, mutation: nil)
    def self.no_coverage          = new(status: :no_coverage, details: nil, subject: nil, mutation: nil)

    def killed?      = status == :killed
    def survived?    = status == :survived
    def error?       = status == :error
    def timeout?     = status == :timeout
    def skipped?     = status == :skipped
    def no_coverage? = status == :no_coverage
  end

  # Aggregates a flat list of Results into counts, the mutation score, and the
  # surviving-mutant list. The score denominator is killed + survived ONLY
  # (KTD-4): no-coverage, skipped (invalid), errored, and timeout are each
  # excluded and surfaced separately. An empty denominator yields a nil score
  # (rendered "N/A"), never 0.0 — distinguishing "no testable mutants" from
  # "0% killed".
  class AggregateResult
    attr_reader :results

    def initialize(results)
      @results = results
      @by_status = results.group_by(&:status)
    end

    def killed_count          = count(:killed)
    def survived_count        = count(:survived)
    def no_coverage_count     = count(:no_coverage)
    def skipped_invalid_count = count(:skipped)
    def errored_count         = count(:error)
    def timeout_count         = count(:timeout)

    # Every generated, classified mutation. NOT the score denominator.
    def total = @results.size

    # The score denominator (also shown to the reader).
    def covered_count = killed_count + survived_count

    # killed / (killed + survived) as a rounded percentage, or nil when nothing
    # was testable.
    def mutation_score
      return nil if covered_count.zero?

      (killed_count.to_f / covered_count * 100).round(1)
    end

    def surviving_mutants = @results.select(&:survived?)

    private

    def count(status) = (@by_status[status] || []).size
  end
end
