# frozen_string_literal: true

module Brutus
  # Summarises a run's Results into a count line and a mutation score. The score
  # is killed / (killed + survived) only — :no_coverage (and :skipped/:error/
  # :timeout) are excluded from the denominator (KTD5/R10).
  #
  # ponytail: counts only; per-mutant file:line listing arrives in M4 once the
  # loop pairs each mutation with its result (M3's Result carries status alone).
  class Reporter
    def self.report(results)
      by    = results.group_by(&:status)
      n     = ->(s) { (by[s] || []).size }
      killed   = n[:killed]
      survived = n[:survived]
      no_cov   = n[:no_coverage]
      denom    = killed + survived
      score    = denom.zero? ? "N/A" : "#{(killed * 100.0 / denom).round(1)}%"

      [
        "Mutations: #{results.size}  Killed: #{killed}  Survived: #{survived}  " \
          "No coverage: #{no_cov}  Skipped: #{n[:skipped]}  Error: #{n[:error]}  Timeout: #{n[:timeout]}",
        "Mutation score: #{score}  (#{no_cov} no-coverage mutants excluded from score)"
      ].join("\n")
    end
  end
end
