# frozen_string_literal: true

require "json"
require "set"
require_relative "config" # for Mutineer::ConfigError
require_relative "project_path"

module Mutineer
  # CI baseline/delta gating. A baseline is a prior
  # `mutineer run --format json` document (no bespoke format to version).
  # Diff the current run against it by survivor id: a NEW survivor
  # (id present now, absent in the baseline) OR a score drop is a regression the
  # CLI turns into exit 1. Pure data, stdlib `json` only, no fork, no Rails, so
  # it is testable in isolation from a canned JSON + a hand-built AggregateResult.
  class Baseline
    # The verdict of diffing a current run against the baseline.
    #   new_survivors   - current Result objects whose id is absent from
    #                     the baseline (the regressions to name).
    #   fixed_survivors - baseline survivor hashes that this run killed or
    #                     ignored, or that it no longer has (informational, never
    #                     gates). Empty when this run has no results, or either
    #                     side is diff-scoped: an out-of-scope baseline survivor
    #                     was never re-tested, so absence does not mean fixed.
    #                     A partial run counts only known kills and ignores.
    #   unverified_survivors - baseline survivor hashes whose current result is
    #                     undecided (not killed, survived or ignored: an error,
    #                     a timeout, ran_at_load, no_coverage and so on), each
    #                     with its current `status`. Not fixed, and never gates.
    #                     Omitted ids in a partial or empty unscoped run use
    #                     `not_run`, a baseline-only label, not a Result status.
    #                     Filled on a diff-scoped side too (#283, #286).
    #   score_drop      - current score < baseline score - epsilon. nil on
    #                     either side skips the check, and a diff-scoped run
    #                     (`scoped: true`) never sets it (see #diff).
    #   score_comparable - the two scores share a denominator (neither side was
    #                     diff-scoped and both are non-nil), so a consumer may
    #                     render them side by side. False means the score-drop
    #                     check was skipped, not that it passed.
    #   regressed       - any new survivors OR a score drop.
    #   incomplete      - the run fails the completeness rule
    #                     (AggregateResult#incomplete?, #78). The CLI fails a
    #                     `--baseline` run on it as well as on `regressed`.
    #   legacy_matches  - current survivors found in an old-format baseline
    #                     (no `summary.id_format`) only through their old-format
    #                     id (#126). Non-zero means the baseline should be
    #                     regenerated; the CLI warns. Always 0 for a new-format
    #                     baseline.
    Delta = Data.define(:new_survivors, :fixed_survivors,
                        :score_before, :score_after, :score_drop, :score_comparable, :regressed,
                        :legacy_matches, :unverified_survivors, :incomplete) do
      # @param legacy_matches [Integer] survivors matched only through an old-format id.
      # @param unverified_survivors [Array<Hash>] stored survivors this run did not decide.
      # @param incomplete [Boolean] the run fails the completeness rule.
      # @return [void]
      def initialize(legacy_matches: 0, unverified_survivors: [], incomplete: false, **) = super
    end

    # The statuses that decide a mutant. Any other current result for a stored
    # survivor leaves it unverified, not fixed.
    DECIDED = %i[killed survived ignored].freeze

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

    # Diff a current AggregateResult against this baseline by survivor id.
    # `epsilon` tolerates float jitter on the score (default 0.0 = any drop
    # gates).
    #
    # A stored survivor is fixed only when this run killed it, ignored it, or no
    # longer has it. When its current result is undecided (an error, a timeout,
    # ran_at_load, no_coverage, ...) the run says nothing about it, so it goes
    # to Delta#unverified_survivors instead. Delta#incomplete carries the
    # completeness rule, so a broken run that errors every stored survivor
    # fails `--baseline` rather than reading as a fix (#283). An empty run
    # cannot verify a fix, so it reports no fixed survivors.
    # `partial: true` marks a run that can omit mutants (`--only`, `--fail-fast`):
    # known kills and ignores still count as fixes, but absent ids do not.
    # Those absent ids are unverified with the baseline-only `not_run` label.
    # With source/operator selections, an absent id outside the selection is
    # also `not_run`. A deleted project file still counts as a genuine fix.
    #
    # `scoped: true` marks the current run as diff-scoped (`--since`): its score
    # is computed over only the changed-line mutants, a different denominator
    # from a full-run baseline, so comparing the two scores manufactures false
    # regressions. A scoped diff keeps the new-survivor gate (ids compare
    # fine across scopes) and still reports both scores, but never sets
    # score_drop.
    #
    # `id_map` maps each current new-format id to its old-format id (#126). A
    # baseline without `summary.id_format` stores old-format ids, so a current
    # survivor matches if its new OR old id is stored, and a stored id seen under
    # either form is not fixed. Matches made only through the old id are counted
    # on Delta#legacy_matches. The old id has no file path, so an old-id match
    # must also come from the same file (the stored survivor's `file`, normalized
    # against `project_root`): an equal old id from another file is a different
    # mutant and stays new. A stored `file` that is absolute and outside
    # `project_root` (a baseline written on another machine) can never equal a
    # current file, so that survivor matches on its old id alone, as before #126.
    #
    # @param aggregate [Mutineer::AggregateResult] current results.
    # @param epsilon [Float] score-drop tolerance.
    # @param scoped [Boolean] current run was diff-scoped (`--since`).
    # @param partial [Boolean] current run can omit mutants (`--only`, `--fail-fast`).
    # @param sources [Array<String>, nil] selected source paths; nil keeps full-source semantics.
    # @param operators [Array<String>, nil] selected operator names; nil keeps all-operator semantics.
    # @param id_map [Hash{String => String}] current new id => old-format id.
    # @param project_root [String] root that survivor `file` paths resolve against.
    # @return [Mutineer::Baseline::Delta] delta summary.
    def diff(aggregate, epsilon: 0.0, scoped: false, partial: false, sources: nil, operators: nil,
             id_map: {}, project_root: Dir.pwd)
      current = aggregate.surviving_mutants
      baseline_ids = @survivors.map { |h| h["id"] }.to_set
      # A new-format baseline never matches on old ids.
      legacy = @id_format.nil? ? id_map : {}
      file_key = ->(path) { path && ProjectPath.relative(path, project_root) }
      source_keys = sources&.map { |path| file_key.call(path) }&.to_set
      operator_names = operators&.map(&:to_s)&.to_set
      # [old id, file] for each stored survivor: an old id alone is ambiguous.
      baseline_pairs = @survivors.map { |h| [h["id"], file_key.call(h["file"])] }.to_set
      # Old ids stored with a file from another machine: matched on the id alone.
      foreign = @survivors.select { |h| foreign_file?(h["file"], file_key) }.to_set
      foreign_ids = foreign.map { |h| h["id"] }.to_set
      legacy_pair = ->(r) { [legacy[r.id], file_key.call(r.subject&.file)] }

      new_survivors = []
      legacy_matches = 0
      current.each do |r|
        next if baseline_ids.include?(r.id)

        if legacy[r.id] && (baseline_pairs.include?(legacy_pair.call(r)) || foreign_ids.include?(legacy[r.id]))
          legacy_matches += 1
        else
          new_survivors << r
        end
      end
      survivor_index = match_index(current, legacy, file_key)
      undecided_index = match_index(aggregate.results.reject { |r| DECIDED.include?(r.status) }, legacy, file_key)
      fixed_index = match_index(aggregate.results.select { |r| r.killed? || r.ignored? }, legacy, file_key)
      # Under a diff-scoped side an out-of-scope baseline survivor was never
      # re-tested, so reporting it "fixed" would be false: empty is honest.
      unscoped = !scoped && !@scoped
      fixed = []
      unverified = []
      @survivors.each do |h|
        next if stored_match(survivor_index, h, foreign, file_key)

        if (r = stored_match(undecided_index, h, foreign, file_key))
          unverified << h.merge("status" => r.status.to_s)
        elsif unscoped
          if stored_match(fixed_index, h, foreign, file_key) ||
             (!partial && aggregate.total.positive? && !outside_selection?(h, source_keys, operator_names, project_root))
            fixed << h
          else
            unverified << h.merge("status" => "not_run")
          end
        end
      end

      current_score = aggregate.mutation_score
      # nil-score discipline (mirrors Reporter#exit_code): a score absent on
      # either side cannot be compared. Skip the drop check, keep the new-
      # survivor check. Same when EITHER side is diff-scoped (the current run
      # via `scoped:`, or the stored baseline via its `summary.scoped` marker):
      # the denominators differ, so the scores are not comparable.
      comparable = unscoped && !@score.nil? && !current_score.nil?
      score_drop = comparable && current_score < @score - epsilon

      Delta.new(new_survivors: new_survivors, fixed_survivors: fixed,
                score_before: @score, score_after: current_score,
                score_drop: score_drop, score_comparable: comparable,
                regressed: !new_survivors.empty? || score_drop, legacy_matches: legacy_matches,
                unverified_survivors: unverified, incomplete: aggregate.incomplete?)
    end

    private

    # Whether an absent stored mutant was excluded by source or operator
    # selection. A missing project file is a removal, but a foreign path cannot
    # prove removal in this checkout. Matched results bypass this metadata check.
    #
    # @param stored [Hash] stored baseline survivor.
    # @param sources [Set<String>, nil] normalized selected source paths.
    # @param operators [Set<String>, nil] selected operator names.
    # @param project_root [String] root for stored project-relative paths.
    # @return [Boolean] whether the stored id was outside the selected scope.
    def outside_selection?(stored, sources, operators, project_root)
      return true if operators && !operators.include?(stored["operator"].to_s)
      return false unless sources

      path = stored["file"]
      return true unless path

      key = ProjectPath.relative(path, ProjectPath.root_real(project_root))
      return false if sources.include?(key)
      return true if File.absolute_path?(key)

      File.exist?(ProjectPath.absolute(path, project_root))
    end

    # Indexes results by the three keys a stored survivor can match on: the
    # current id, the `[old id, file]` pair, and the old id alone (for a stored
    # file from another machine). The first result for a key wins.
    #
    # @param results [Array<Mutineer::Result>] the current results to index.
    # @param legacy [Hash{String => String}] current new id => old-format id.
    # @param file_key [Proc] normalizes a path against the project root.
    # @return [Hash{Symbol => Hash}] `{ id:, pair:, old_id: }` lookups.
    def match_index(results, legacy, file_key)
      index = { id: {}, pair: {}, old_id: {} }
      results.each do |r|
        index[:id][r.id] ||= r unless r.id.nil?
        old = legacy[r.id]
        next unless old

        index[:pair][[old, file_key.call(r.subject&.file)]] ||= r
        index[:old_id][old] ||= r
      end
      index
    end

    # The current result a stored survivor matches in an index, or nil.
    #
    # @param index [Hash{Symbol => Hash}] from {#match_index}.
    # @param stored [Hash] a stored survivor.
    # @param foreign [Set<Hash>] stored survivors whose file is from another machine.
    # @param file_key [Proc] normalizes a path against the project root.
    # @return [Mutineer::Result, nil]
    def stored_match(index, stored, foreign, file_key)
      index[:id][stored["id"]] || index[:pair][[stored["id"], file_key.call(stored["file"])]] ||
        (index[:old_id][stored["id"]] if foreign.include?(stored))
    end

    # True when a stored survivor's `file` is absolute and still absolute after
    # normalizing against the project root, so it lies outside this checkout.
    #
    # @param file [String, nil] the stored survivor's `file`.
    # @param file_key [Proc] normalizes a path against the project root.
    # @return [Boolean] whether the file can never equal a current file.
    def foreign_file?(file, file_key)
      !file.nil? && File.absolute_path?(file) && File.absolute_path?(file_key.call(file))
    end
  end
end
