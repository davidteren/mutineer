# frozen_string_literal: true

require "json"
require_relative "config" # for Mutineer::ConfigError

module Mutineer
  # #13: CI baseline/delta gating. A baseline is literally a prior
  # `mutineer run --format json` document (KTD-1) — no bespoke format to
  # version.
  # We diff the current run against it by the #10 stable survivor id (KTD-2):
  # a NEW survivor (id present now, absent in the baseline) OR a score drop is
  # a regression the CLI turns into exit 1. Pure data — stdlib `json` only, no
  # fork, no Rails — so it's testable in isolation from a canned JSON + a hand-
  # built AggregateResult.
  class Baseline
    # The verdict of diffing a current run against the baseline.
    #   new_survivors   — current Result objects whose stable id is absent from
    #                     the baseline (the regressions to name).
    #   fixed_survivors — baseline survivor hashes absent from the current run
    #                     (informational, never gates).
    #   score_drop      — current score < baseline score - epsilon. nil on
    #                     either side skips the check (see #diff).
    #   regressed       — any new survivors OR a score drop.
    Delta = Data.define(:new_survivors, :fixed_survivors,
                        :score_before, :score_after, :score_drop, :regressed)

    # Load a prior --format json run. Raises ConfigError (NOT exit — R8: a data
    # class must never kill the host) on a missing/unreadable file, unparseable
    # JSON, or a doc that isn't a baseline shape, so the CLI maps it to exit 2
    # (usage) like every other bad-path flag.
    #
    # @param path [String] baseline JSON file path.
    # @return [Mutineer::Baseline] baseline object.
    # @raise [Mutineer::ConfigError] when the file is missing or invalid.
    def self.load(path)
      doc = JSON.parse(File.read(path))
      unless doc.is_a?(Hash) && doc["schema_version"] && doc["survivors"].is_a?(Array)
        raise ConfigError, "not a Mutineer JSON report: #{path}"
      end

      new(doc)
    rescue JSON::ParserError => e
      raise ConfigError, "invalid baseline JSON in #{path}: #{e.message}"
    end

    attr_reader :score

    # Builds a baseline from a JSON document.
    #
    # The baseline retains the survivor document and score from the JSON report.
    #
    # @param doc [Hash] parsed JSON document.
    def initialize(doc)
      @survivors = doc["survivors"] || []
      @score = doc.dig("summary", "score")
    end

    # Diff a current AggregateResult against this baseline by stable survivor id.
    # `epsilon` tolerates float jitter on the score (default 0.0 = any drop
    # gates).
    #
    # @param aggregate [Mutineer::AggregateResult] current results.
    # @param epsilon [Float] score-drop tolerance.
    # @return [Mutineer::Baseline::Delta] delta summary.
    def diff(aggregate, epsilon: 0.0)
      current = aggregate.surviving_mutants
      current_ids = current.map(&:id)
      baseline_ids = @survivors.map { |h| h["id"] }

      new_survivors = current.reject { |r| baseline_ids.include?(r.id) }
      fixed = @survivors.reject { |h| current_ids.include?(h["id"]) }

      current_score = aggregate.mutation_score
      # nil-score discipline (mirrors Reporter#exit_code): a score absent on
      # either side can't be compared — skip the drop check, keep the new-
      # survivor check.
      score_drop = !@score.nil? && !current_score.nil? &&
                   current_score < @score - epsilon

      Delta.new(new_survivors: new_survivors, fixed_survivors: fixed,
                score_before: @score, score_after: current_score,
                score_drop: score_drop,
                regressed: !new_survivors.empty? || score_drop)
    end
  end
end
