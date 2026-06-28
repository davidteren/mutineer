# frozen_string_literal: true

module Brutus
  # Immutable outcome of running one mutant. Five distinct states:
  #   killed    — a test failed/errored, so the mutation was caught.
  #   survived  — every test passed, so the mutation went undetected.
  #   error     — the child crashed (unhandled exception): exit status 2.
  #   timeout   — the parent SIGKILLed a child that overran its wall clock.
  #   skipped   — the mutated source failed to re-parse (invalid); no fork.
  #
  # `error` and `skipped` are deliberately distinct: skipped is a pre-fork
  # validity failure (counted separately by the reporter), error is a runtime
  # crash. Never conflate them via `details` string parsing.
  Result = Data.define(:status, :details) do
    def self.killed              = new(status: :killed, details: nil)
    def self.survived            = new(status: :survived, details: nil)
    def self.error(details = nil) = new(status: :error, details: details)
    def self.timeout             = new(status: :timeout, details: nil)
    def self.skipped(details = nil) = new(status: :skipped, details: details)

    def killed?   = status == :killed
    def survived? = status == :survived
    def error?    = status == :error
    def timeout?  = status == :timeout
    def skipped?  = status == :skipped
  end
end
