# frozen_string_literal: true

require "json"
require_relative "config" # for Mutineer::ConfigError

module Mutineer
  # CI baseline/delta gating. A baseline is a prior
  # `mutineer run --format json` document (no bespoke format to version).
  # Diff the current run against it by the stable survivor id: a NEW survivor
  # (id present now, absent in the baseline) OR a score drop is a regression the
  # CLI turns into exit 1. Pure data, stdlib `json` only, no fork, no Rails, so
  # it is testable in isolation from a canned JSON + a hand-built AggregateResult.
  class Baseline
    # The verdict of diffing a current run against the baseline.
    #   new_survivors   - current Result objects whose stable id is absent from
    #                     the baseline (the regressions to name).
    #   fixed_survivors - baseline survivor hashes absent from the current run
    #                     (informational, never gates). Empty when either side
    #                     is diff-scoped: an out-of-scope baseline survivor was
    #                     never re-tested, so absence does not mean fixed.
    #   score_drop      - current score < baseline score - epsilon. nil on
    #                     either side skips the check, and a diff-scoped run
    #                     (`scoped: true`) never sets it (see #diff).
    #   score_comparable - the two scores share a denominator (neither side was
    #                     diff-scoped and both are non-nil), so a consumer may
    #                     render them side by side. False means the score-drop
    #                     check was skipped, not that it passed.
    #   regressed       - any new survivors OR a score drop.
    #   legacy_matches  - current survivors found in an old-format baseline
    #                     (no `summary.id_format`) only through their old-format
    #                     id (#126). Non-zero means the baseline should be
    #                     regenerated; the CLI warns. Always 0 for a new-format
    #                     baseline.
    Delta = Data.define(:new_survivors, :fixed_survivors,
                        :score_before, :score_after, :score_drop, :score_comparable, :regressed,
                        :legacy_matches) do
      # @param legacy_matches [Integer] survivors matched only through an old-format id.
      # @return [void]
      def initialize(legacy_matches: 0, **) = super
    end

    # Load a prior --format json run. Raises ConfigError (NOT exit: a data class
    # must never kill the host) on a missing/unreadable file, unparseable JSON,
    # or a doc that is not a baseline shape, so the CLI maps it to exit 2
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
      # A diff-scoped report covers only that diff's mutants: used as a
      # baseline, every survivor outside the original diff would read as a NEW
      # regression, and its score shares no denominator with any other run.
      # Refuse loudly (exit 2 via the CLI) rather than gate unreliably.
      if doc.dig("summary", "scoped") == true
        raise ConfigError, "#{path} was written by a --since run and covers only that diff's " \
                           "mutants; regenerate the baseline from a full run " \
                           "(use --no-since if .mutineer.yml sets since:)"
      end

      new(doc)
    rescue JSON::ParserError => e
      raise ConfigError, "invalid baseline JSON in #{path}: #{e.message}"
    end

    attr_reader :score

    # Builds a baseline from a JSON document.
    #
    # The baseline retains the survivor document, score, and scope marker from
    # the JSON report. A report whose `summary.scoped` is true came from a
    # `--since` run: its score covers only changed-line mutants, so later diffs
    # must not compare a full-run score against it.
    #
    # @param doc [Hash] parsed JSON document.
    def initialize(doc)
      @survivors = doc["survivors"] || []
      @score = doc.dig("summary", "score")
      # Strict literal true only: a malformed value (say the STRING "false" in a
      # hand-edited baseline) must not silently disable the score-drop gate.
      @scoped = doc.dig("summary", "scoped") == true
      # nil for a report written before ids included the file path (#126).
      @id_format = doc.dig("summary", "id_format")
    end

    # Diff a current AggregateResult against this baseline by stable survivor id.
    # `epsilon` tolerates float jitter on the score (default 0.0 = any drop
    # gates).
    #
    # `scoped: true` marks the current run as diff-scoped (`--since`): its score
    # is computed over only the changed-line mutants, a different denominator
    # from a full-run baseline, so comparing the two scores manufactures false
    # regressions. A scoped diff keeps the new-survivor gate (stable ids compare
    # fine across scopes) and still reports both scores, but never sets
    # score_drop.
    #
    # `id_map` maps each current new-format id to its old-format id (#126). A
    # baseline without `summary.id_format` stores old-format ids, so a current
    # survivor matches if its new OR old id is stored, and a stored id seen under
    # either form is not fixed. Matches made only through the old id are counted
    # on Delta#legacy_matches. The old id has no file path, so this can hide a new
    # survivor whose old id equals a stored survivor from another file.
    #
    # @param aggregate [Mutineer::AggregateResult] current results.
    # @param epsilon [Float] score-drop tolerance.
    # @param scoped [Boolean] current run was diff-scoped (`--since`).
    # @param id_map [Hash{String => String}] current new id => old-format id.
    # @return [Mutineer::Baseline::Delta] delta summary.
    def diff(aggregate, epsilon: 0.0, scoped: false, id_map: {})
      current = aggregate.surviving_mutants
      baseline_ids = @survivors.map { |h| h["id"] }.to_set
      # A new-format baseline never matches on old ids.
      legacy = @id_format.nil? ? id_map : {}

      new_survivors = []
      legacy_matches = 0
      current.each do |r|
        next if baseline_ids.include?(r.id)

        old = legacy[r.id]
        if old && baseline_ids.include?(old)
          legacy_matches += 1
        else
          new_survivors << r
        end
      end
      current_ids = current.flat_map { |r| [r.id, legacy[r.id]] }.compact.to_set
      # Under a diff-scoped side an out-of-scope baseline survivor was never
      # re-tested, so reporting it "fixed" would be false: empty is honest.
      fixed = if scoped || @scoped
                []
              else
                @survivors.reject { |h| current_ids.include?(h["id"]) }
              end

      current_score = aggregate.mutation_score
      # nil-score discipline (mirrors Reporter#exit_code): a score absent on
      # either side cannot be compared. Skip the drop check, keep the new-
      # survivor check. Same when EITHER side is diff-scoped (the current run
      # via `scoped:`, or the stored baseline via its `summary.scoped` marker):
      # the denominators differ, so the scores are not comparable.
      comparable = !scoped && !@scoped && !@score.nil? && !current_score.nil?
      score_drop = comparable && current_score < @score - epsilon

      Delta.new(new_survivors: new_survivors, fixed_survivors: fixed,
                score_before: @score, score_after: current_score,
                score_drop: score_drop, score_comparable: comparable,
                regressed: !new_survivors.empty? || score_drop, legacy_matches: legacy_matches)
    end
  end
end
