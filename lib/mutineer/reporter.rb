# frozen_string_literal: true

require "json"
require "stringio"
require "cgi"
require_relative "mutation"
require_relative "redaction"
require_relative "result"

module Mutineer
  # Renders an AggregateResult: the summary block, mutation score, and per-file
  # survivor diffs. Stream discipline: the report goes to `out` (stdout),
  # diagnostics/warnings go to `err` (stderr), so `mutineer ... > report.txt`
  # captures only the report.
  #
  # `source_map` is { file_path => raw source string }, used to extract the
  # containing source line for each survivor diff.
  class Reporter
    # The JSON report's `schema_version` (see docs/json-schema.md).
    SCHEMA_VERSION = "2.0"

    # Compatibility name for the aggregate's incomplete-run share limit.
    BROKEN_SHARE_LIMIT = AggregateResult::BROKEN_SHARE_LIMIT

    # Compatibility name for the aggregate's incomplete-run count floor.
    BROKEN_FLOOR = AggregateResult::BROKEN_FLOOR

    # Share of the mutants a run tried to score that may go unrun (unplaceable,
    # skipped invalid, or unpaired) before stderr warns. A warning only: it
    # never changes the exit code. {BROKEN_FLOOR} also applies, so one unrun
    # mutant never warns. `--fail-fast` leaves unpaired mutants out of this share.
    # Measured on Fizzy at f220e4832 (#349): unplaceable plus skipped invalid were
    # 0.12% with the default operators and at most 2.8% with all 21, so 10% stays.
    # With its unpaired mutants the share was 15.2%. That warning is correct.
    UNRUN_SHARE_LIMIT = 0.10

    # The unrun-share hint for mutants in sources with no paired test.
    # The CLI keeps a shorter copy for the empty-run message.
    UNPAIRED_SHARE_HINT = "See unpaired_sources[] in --format json. To run them, add a test " \
                          "at the conventional path, or run those sources in a separate command with --test."

    # The warning both matrix renderers give under the redundant tests.
    MATRIX_REDUNDANT_NOTE = "Delete redundant tests one at a time: two of them can be the only killers of one mutant."

    # How many blind or redundant tests the human report lists before it points
    # to `--format json` for the rest.
    MATRIX_LIST_LIMIT = 20
    # Shown for an errored mutant whose run recorded no cause (#480).
    ERRORED_NO_CAUSE = "no cause recorded; stderr of the run may name it"

    # @param aggregate [Mutineer::AggregateResult] the run's results.
    # @param source_map [Hash{String => String}] source file path => source text.
    # @param matrix [Mutineer::KillMatrix, nil] the kill matrix of a `--matrix`
    #   run; nil leaves every format exactly as it is without the flag.
    # @param unpaired [Hash{String => Integer, nil}] file => mutant count for
    #   sources pairing skipped. nil means the count failed. Default is empty.
    # @param fail_fast [Boolean] when true, unpaired mutants stay out of the
    #   unrun share and the human scope percentage.
    def initialize(aggregate, source_map, matrix: nil, unpaired: {}, fail_fast: false)
      @agg = aggregate
      @source_map = source_map
      @matrix = matrix
      @unpaired = unpaired
      @fail_fast = fail_fast
      @copies = {}
      @timing = nil
      @callback_growth = nil
    end

    # Single entry point. Branches on `format` ("human" | "json" | "html") and
    # routes the rendered report to `output` (a file, with a stderr confirmation)
    # or to `out`. Diagnostics always go to `err`. `scoped` marks a diff-scoped
    # (`--since`) run; the JSON report records it so a consumer (or a later
    # `--baseline` load) knows the score covers only the changed-line mutants.
    # `legacy_id_matches` (`{ignore:, baseline:}`) counts stored ids still in the
    # old format (#126); only the JSON report records it (`summary.legacy_id_matches`).
    # `unmatched_ignores` is the `ignore:` ids that matched no mutant in this
    # run (#377); only the JSON report records them (`summary.unmatched_ignores`).
    # An empty list under `--only` means the check was skipped, not that every
    # entry matched.
    # `declined` (operator name => count, from {JobPlan.collect_jobs}) counts the
    # candidates the operators did not mutate; the JSON and human reports show it.
    # `subjects` (methods discovered) and `unmutated_subjects` (one
    # `{subject:, file:, line:}` hash per method the operators did not mutate,
    # from {JobPlan.collect_jobs}, #386) feed the same two reports. Left out,
    # they are unknown: JSON reports null and the human report has no row. The
    # two are one unit: when either is left out, both are unknown.
    # `copies` (kept mutant id => dropped repeat ids, from {JobPlan.collect_jobs},
    # #374) is listed on each kept mutant and counted in `summary.dropped`.
    # An empty hash reports zero. The count covers mutants in this report,
    # so `--fail-fast` leaves out copies of mutants it did not schedule.
    # `timing` (#495) holds `total_seconds` and the four phase seconds, each a
    # Float or nil. The JSON report writes it as `timing` and the human report
    # prints a `Time:` line. Left out, JSON has `timing: null` and no line prints.
    # `callback_growth` (#505) is each class name and file whose callback count
    # grew after a reload, from {Runner.execute}. Only the JSON report records
    # it (`summary.callback_growth`, sorted). Left out, or nil when the run made
    # no log, JSON has `callback_growth: null`.
    def report(out: $stdout, err: $stderr, threshold: 0.0, format: "human", output: nil,
               baseline: nil, scoped: false, legacy_id_matches: { ignore: 0, baseline: 0 },
               unmatched_ignores: [], declined: {},
               subjects: nil, unmutated_subjects: nil, copies: {}, timing: nil,
               callback_growth: nil, verbose: false)
      @copies = copies || {}
      @timing = timing
      @callback_growth = callback_growth
      subjects = unmutated_subjects = nil if subjects.nil? || unmutated_subjects.nil?
      rendered =
        if format == "json"
          json_report(baseline, scoped: scoped, legacy_id_matches: legacy_id_matches,
                                unmatched_ignores: unmatched_ignores, declined: declined,
                                subjects: subjects, unmutated_subjects: unmutated_subjects)
        elsif format == "html"
          html_report(declined: declined, subjects: subjects, unmutated: unmutated_subjects&.size,
                      scoped: scoped)
        else
          sio = StringIO.new
          human_report(sio, err, threshold, declined: declined, scoped: scoped,
                                            subjects: subjects, unmutated: unmutated_subjects&.size,
                                            verbose: verbose)
          baseline_section(sio, baseline) if baseline
          sio.string
        end

      if output
        abs = File.expand_path(output)
        File.write(abs, rendered)
        err.puts "Report written to #{abs}"
      else
        out.print rendered
      end

      warn_unrun_share(err)
      # --baseline gates on completeness on its own (#283); --threshold always does.
      gates = []
      gates << "--threshold" if threshold&.positive?
      gates << "--baseline" if baseline&.incomplete
      return warn_errors_without_gate(err) if gates.empty?

      fails = gates.size == 1 ? "the #{gates.first} gate fails" : "the #{gates.join(' and ')} gates fail"
      # Both ways a run can fail the gate on completeness, said here rather than in
      # the human renderer: --format json is the documented CI path, and a run that
      # exits 1 must say why on every format, not only the one a person reads.
      if @agg.broken_nil_score?
        err.puts "[mutineer] nothing could be scored (#{broken_counts_detail}), so " \
                 "#{fails}. See no_verdict[] in --format json for the cause of each."
      elsif @agg.broken_share_exceeded?
        err.puts "[mutineer] #{no_verdict_ratio}: #{broken_counts_detail}. The score covers " \
                 "only part of the run, so #{fails}. See no_verdict[] in " \
                 "--format json for the cause of each."
      end
    end

    # Errors are out of the score, so a run that no gate fails on completeness
    # passes however many mutants errored. Say so, and say what --threshold and
    # --baseline enforce.
    #
    # @api private
    # @param err [IO] error stream.
    # @return [void]
    def warn_errors_without_gate(err)
      count = @agg.errored_count
      return unless count.positive?

      err.puts "[mutineer] #{count} #{count == 1 ? 'mutant' : 'mutants'} errored. Errors are not in the " \
               "score, so they do not fail a run on their own. With a positive --threshold, or with " \
               "--baseline, the run fails when nothing can be scored, or when more than one mutant has no verdict and they exceed " \
               "#{(AggregateResult::BROKEN_SHARE_LIMIT * 100).round}% of those attempted (no_verdict[] in --format json)."
    end

    # Warns when the unrun mutants (unplaceable plus skipped invalid) are more
    # than {UNRUN_SHARE_LIMIT} of the mutants the run tried to score, and more
    # than {BROKEN_FLOOR}. Every format, with or without --threshold; the exit
    # code does not change.
    #
    # @api private
    # @param err [IO] error stream.
    # @return [void]
    def warn_unrun_share(err)
      return unless unrun_share_exceeded?

      include_unpaired = unpaired_in_share?
      unrun = unrun_for_share
      tried = @agg.attempted_count + unrun
      parts = []
      parts << "#{@agg.unplaceable_count} unplaceable" if @agg.unplaceable_count.positive?
      parts << "#{@agg.skipped_invalid_count} skipped (invalid)" if @agg.skipped_invalid_count.positive?
      parts << "#{unpaired_mutant_count} in sources with no paired test" if include_unpaired
      pct = (unrun * 100.0 / tried).round(1)
      message = +"[mutineer] #{unrun} of the #{tried} mutants mutineer tried to score were not run " \
                 "(#{parts.join(', ')}; #{pct}%, limit #{(UNRUN_SHARE_LIMIT * 100).round}%). " \
                 "The score leaves them out. This warning does not change the exit code."
      if @agg.unplaceable_count.positive?
        message << " See unplaceable[] in --format json; --test-command runs them."
      end
      if @agg.skipped_invalid_count.positive?
        message << " A mutant skipped (invalid) did not re-parse after mutation. If its source file " \
                   "parses on its own, that is a mutineer bug: please report it at " \
                   "https://github.com/davidteren/mutineer/issues, with the source file and " \
                   "these versions: Ruby #{RUBY_VERSION}, Prism #{Prism::VERSION}."
      end
      message << " #{UNPAIRED_SHARE_HINT}" if include_unpaired
      err.puts message
    end

    # Renders the human report.
    #
    # @param out [IO] output stream.
    # @param err [IO] error stream.
    # @param threshold [Float] score threshold.
    # @param declined [Hash{String => Integer}] operator name => declined count.
    # @param scoped [Boolean] the run was diff-scoped (`--since`).
    # @param subjects [Integer, nil] methods discovered; nil when unknown.
    # @param unmutated [Integer, nil] methods the selected operators did not mutate; nil when unknown.
    # @param verbose [Boolean] also list each errored mutant and its cause (#480).
    # @return [void]
    def human_report(out, err, threshold, declined: {}, scoped: false, subjects: nil, unmutated: nil,
                     verbose: false)
      # The CLI explains an empty run for every format (CLI.warn_empty_run).
      # A saved report still carries the unpaired counts.
      if @agg.total.zero?
        out.puts unpaired_line(scoped) unless @unpaired.empty?
        return
      end

      out.puts "Mutineer — Mutation Results"
      out.puts "========================="
      out.puts
      summary(out, declined: declined, scoped: scoped, subjects: subjects, unmutated: unmutated)
      out.puts
      score_line(out, err)
      per_source(out)

      survivors(out)
      errored(out) if verbose
      matrix_section(out) if @matrix
      verdict(out, threshold) if threshold && threshold.positive?
    end

    # 0 pass / 1 below threshold or untestable-with-errors. Usage errors (exit 2)
    # are the CLI's job. When the score is nil (nothing killed or survived), pure
    # no_coverage / all-ignored / empty still skip the gate; if any mutant was
    # errored, timed out, or uncapturable, fail the gate so a broken harness
    # cannot green CI under --threshold.
    def exit_code(threshold:)
      return 0 if threshold.nil? || threshold <= 0

      # An incomplete run fails first. A score computed over a small slice of
      # what was attempted is not this suite's score: without this, 90 errored
      # mutants and 10 that ran (9 killed) reports 90% and exits 0, so CI cannot
      # tell a complete run from a broken one.
      return 1 if @agg.incomplete?

      score = @agg.mutation_score
      return 0 if score.nil? # pure no_coverage / ignored / empty — gate skipped

      @agg.meets_threshold?(threshold) ? 0 : 1
    end

    private

    # Canonical machine-readable schema. survivors/no_coverage are sorted by
    # (file, line, operator) so output is byte-stable regardless of --jobs
    # worker finish order.
    #
    # @api private
    # @param baseline [Mutineer::Baseline::Delta, nil] baseline delta.
    # @param scoped [Boolean] the run was diff-scoped (`--since`), so its score
    #   covers only the changed-line mutants (additive `summary.scoped` key).
    # @param legacy_id_matches [Hash{Symbol => Integer}] `{ignore:, baseline:}`:
    #   old-format ignore entries that matched, and survivors matched in an
    #   old-format baseline only through their old id (#126).
    # @param unmatched_ignores [Array<String>] `ignore:` ids that matched no
    #   mutant in this run, in file order, each once (#377). Empty under
    #   `--only`, which skips the check.
    # @return [String] JSON text.
    # @param declined [Hash{String => Integer}] operator name => count of
    #   candidates that operator did not mutate (additive `summary.declined`
    #   and `summary.declined_by_operator` keys).
    # @param subjects [Integer, nil] methods discovered (additive `summary.subjects`);
    #   nil (JSON null) when the caller did not supply it, never a made-up 0.
    # @param unmutated_subjects [Array<Hash>, nil] `{subject:, file:, line:}` per method
    #   the operators did not mutate, already sorted (additive
    #   `summary.unmutated_subjects` count and top-level `unmutated_subjects[]`);
    #   nil (JSON null for both) when not supplied.
    def json_report(baseline = nil, scoped: false, legacy_id_matches: { ignore: 0, baseline: 0 },
                    unmatched_ignores: [], declined: {},
                    subjects: nil, unmutated_subjects: nil)
      killed = @agg.killed_count
      survived = @agg.survived_count
      # null (not 0.0) on an empty denominator, matching the nil-vs-0.0
      # discipline in AggregateResult; and the SAME rounding as the human report
      # (one run must not yield two scores by --format).
      score = @agg.mutation_score

      doc = {
        schema_version: SCHEMA_VERSION,
        summary: {
          total: @agg.total, killed: killed, survived: survived,
          no_coverage: @agg.no_coverage_count,
          uncapturable: @agg.uncapturable_count,
          unplaceable: @agg.unplaceable_count,
          ran_at_load: @agg.ran_at_load_count,
          skipped_invalid: @agg.skipped_invalid_count,
          errored: @agg.errored_count, timeout: @agg.timeout_count,
          ignored: @agg.ignored_count,
          # Additive (1.10, #374): repeats of a kept mutant that were not run.
          # Not in `total` and not in the score. The ids sit on `copies`.
          dropped: dropped_count,
          # The gate is computed from these two, so a consumer never re-derives them.
          attempted: @agg.attempted_count, no_verdict: @agg.no_verdict_count,
          score: score,
          # Additive: true when the run was diff-scoped (--since). The score then
          # covers only the changed-line mutants, so it is not comparable to a
          # full-run score; Baseline#diff reads this to skip the score-drop gate.
          scoped: scoped,
          # Additive (1.4, #126): ids hash the project-relative file path. A
          # baseline without this key stores old-format ids; Baseline#diff then
          # also matches on old ids.
          id_format: 2,
          # Additive (1.4, #126): stored ids still in the old format. `ignore` is
          # the number of old-format ignore entries that matched; `baseline` the
          # survivors matched in the baseline only through their old id.
          legacy_id_matches: legacy_id_matches,
          # Additive (1.10, #377): ignore ids that matched no mutant in this
          # run's sources and operators. File order, each id once. Empty under
          # --only, because that check is skipped. The exit code stays 0.
          unmatched_ignores: unmatched_ignores,
          # Additive (1.9, #291): candidates the operators found and did not
          # mutate (a heredoc split or an equivalent skip), so not in `total`.
          declined: declined.values.sum,
          declined_by_operator: declined,
          # Additive (1.10, #381): sources pairing skipped, and the mutants in
          # them. A nil count is left out of the mutant sum.
          unpaired_sources: @unpaired.size,
          unpaired_mutants: unpaired_mutant_count,
          # Additive (1.10, #386): methods discovered, and how many of them the
          # selected operators did not mutate. Not mutants, so not in `total`.
          subjects: subjects,
          unmutated_subjects: unmutated_subjects&.size,
          # Additive (1.11, #505): the classes the stderr callback warning
          # names, as { class, file } rows. null when the run made no log.
          # Changes no verdict, score or exit code.
          callback_growth: callback_growth_json
        },
        survivors: @agg.surviving_mutants.map { |r| survivor_json(r) }
                       .sort_by { |h| [h[:file], h[:line], h[:operator]] },
        # Additive (1.10, #361): every killed mutant's lean identity so two runs
        # can be joined by id without subtracting every unscored category.
        # Additive (1.11, #498): its diff, as on survivors.
        # to_s/to_i: lean_mutant_json can leave null fields when a stub result
        # lacks a subject (same rule as no_verdict[]).
        killed: @agg.results.select(&:killed?).map { |r| mutant_with_diff_json(r, seconds: true) }
                    .sort_by { |h| [h[:file].to_s, h[:line].to_i, h[:operator].to_s, h[:id].to_s] },
        # id extends the key to a total order: several mutants share a line.
        no_coverage: @agg.results.select(&:no_coverage?).map { |r| mutant_json(r) }
                         .sort_by { |h| [h[:file], h[:line], h[:operator], h[:id].to_s] },
        # Same shape as no_coverage; additive key.
        uncapturable: @agg.results.select(&:uncapturable?).map { |r| mutant_json(r) }
                          .sort_by { |h| [h[:file], h[:line], h[:operator], h[:id].to_s] },
        # Additive (1.7): owner-unknown mutants redefine did not run. Not in no_verdict.
        # Additive (1.11, #498): the diff, so a consumer can run them itself.
        unplaceable: @agg.results.select(&:unplaceable?).map { |r| mutant_with_diff_json(r) }
                         .sort_by { |h| [h[:file], h[:line], h[:operator], h[:id].to_s] },
        # Additive (1.7, #187): mutants on a line that ran at load. Not in no_verdict.
        # Additive (1.11, #498): the diff, as on unplaceable.
        ran_at_load: @agg.results.select(&:ran_at_load?).map { |r| mutant_with_diff_json(r) }
                         .sort_by { |h| [h[:file], h[:line], h[:operator], h[:id].to_s] },
        # Every mutant that was attempted and produced no verdict, whatever the
        # reason — the set the --threshold completeness gate counts. Named for the
        # condition rather than one status, because summary.errored means :error
        # alone and a key that reconciled with neither would be worse. `details`
        # carries the cause where there is one. Uncapturable mutants also appear in
        # uncapturable[], which stays for consumers that already read it.
        # Additive (1.11, #526): the diff, as on killed, so a consumer can run
        # an errored mutant again; uncapturable[] stays lean.
        # to_s/to_i because a pre-fork failure has no subject, so its file and line
        # are null and would not compare against a real entry. id and status extend
        # the key to a total order: these entries collide on (file, line) far more
        # than survivors do — several mutants on one crashy line, every pre-fork
        # entry on ("", 0) — and sort_by is not stable, so equal keys would leave
        # worker finish order in the output and break the byte-stability promise.
        no_verdict: @agg.results.select { |r| r.error? || r.timeout? || r.uncapturable? }
                        .map { |r| no_verdict_json(r) }
                        .sort_by { |h| [h[:file].to_s, h[:line].to_i, h[:id].to_s, h[:status].to_s, h[:details].to_s] },
        # Equivalent mutants the user suppressed: emitted with their stable id so
        # the user can audit what is silenced (and copy ids for survivors they
        # want to add). Excluded from the score; never in `survivors`.
        ignored: @agg.results.select(&:ignored?).map { |r| ignored_json(r) }
                     .sort_by { |h| [h[:file], h[:line], h[:operator], h[:id].to_s] },
        # Per-source breakdown (additive; baseline consumes it). Sorted by file so
        # output is byte-stable. Reuses AggregateResult via by_source.
        per_source: @agg.by_source.map { |file, agg| per_source_json(file, agg) }
                        .sort_by { |h| h[:file] },
        # Additive (1.10, #381): every source pairing skipped, sorted by file.
        # `mutants` is null when the count failed.
        unpaired_sources: unpaired_sources_json,
        # Additive (1.10, #386): the methods the selected operators did not
        # mutate, sorted by (file, line, subject) in JobPlan.collect_jobs.
        unmutated_subjects: unmutated_subjects,
        # Additive (1.11, #495): wall-clock seconds of the run and its phases,
        # null when the caller gave none. Wall-clock, so not byte-stable.
        timing: @timing&.transform_values { |v| v&.round(3) }
      }
      # Additive (1.5): the kill matrix, present only with --matrix.
      doc[:matrix] = matrix_json if @matrix
      # Additive baseline-delta block, present only with --baseline. Existing
      # consumers ignore the extra key; it does not move schema_version on its own.
      doc[:baseline] = baseline_json(baseline) if baseline
      "#{JSON.generate(json_safe(doc))}\n"
    end

    # One self-contained HTML file (inline CSS, no external assets): the overall
    # score + summary counts, a per-source table, and every surviving mutant with
    # its stable id and diff. All source/diff/identifier text is HTML-escaped
    # (CGI.escapeHTML) so a `<`/`>` in source can never break the markup. Reuses
    # survivor_json/per_source_json so one run yields one set of facts regardless
    # of --format.
    # @param declined [Hash{String => Integer}] candidates declined by operators.
    # @param subjects [Integer, nil] methods discovered (in scope).
    # @param unmutated [Integer, nil] methods with no mutants (#419).
    # @param scoped [Boolean] the run was diff-scoped (`--since`); declined keeps
    #   its full-run count and the HTML label says so.
    def html_report(declined: {}, subjects: nil, unmutated: nil, scoped: false)
      score = @agg.mutation_score
      survivors = @agg.surviving_mutants.map { |r| survivor_json(r) }
                      .sort_by { |h| [h[:file], h[:line], h[:operator]] }
      per_source = @agg.by_source.map { |file, agg| per_source_json(file, agg) }
                       .sort_by { |h| h[:file] }

      <<~HTML
        <!DOCTYPE html>
        <html lang="en">
        <head>
        <meta charset="utf-8">
        <meta name="viewport" content="width=device-width, initial-scale=1">
        <title>Mutineer Mutation Report</title>
        <style>
          body { font-family: -apple-system, Segoe UI, Roboto, Helvetica, Arial, sans-serif;
                 margin: 2rem; color: #1b1b1b; background: #fafafa; }
          h1 { margin: 0 0 .25rem; }
          .score { font-size: 2.5rem; font-weight: 700; }
          .counts { color: #444; margin: .5rem 0 1.5rem; }
          .counts span { display: inline-block; margin-right: 1rem; white-space: nowrap; }
          table { border-collapse: collapse; width: 100%; margin-bottom: 2rem; background: #fff; }
          th, td { border: 1px solid #ddd; padding: .4rem .6rem; text-align: left; }
          th { background: #f0f0f0; }
          td.num { text-align: right; font-variant-numeric: tabular-nums; }
          .survivor { background: #fff; border: 1px solid #ddd; border-radius: 4px;
                      padding: .75rem 1rem; margin-bottom: 1rem; }
          .survivor h3 { margin: 0 0 .25rem; font-size: 1rem; }
          .meta { color: #555; font-size: .85rem; margin-bottom: .5rem; }
          .id { font-family: ui-monospace, SFMono-Regular, Menlo, Consolas, monospace; }
          pre.diff { font-family: ui-monospace, SFMono-Regular, Menlo, Consolas, monospace;
                     background: #f6f8fa; padding: .5rem .75rem; overflow-x: auto;
                     margin: 0; border-radius: 4px; }
          .diff .add { color: #116329; }
          .diff .del { color: #82071e; }
        </style>
        </head>
        <body>
        <h1>Mutineer — Mutation Report</h1>
        <div class="score">Score: #{score.nil? ? 'N/A' : "#{score}%"}</div>
        #{summary_html(declined: declined, subjects: subjects, unmutated: unmutated, scoped: scoped)}
        #{unpaired_html}
        #{per_source_html(per_source)}
        #{survivors_html(survivors)}
        #{ignored_html}
        #{errored_html}
        #{matrix_html}
        </body>
        </html>
      HTML
    end

    # The summary counts block for the HTML header.
    #
    # @param declined [Hash{String => Integer}]
    # @param subjects [Integer, nil]
    # @param unmutated [Integer, nil]
    # @param scoped [Boolean] when true, the declined label notes it is not
    #   narrowed by `--since` (same wording as the human report).
    def summary_html(declined: {}, subjects: nil, unmutated: nil, scoped: false)
      counts = {
        "total" => @agg.total, "killed" => @agg.killed_count,
        "survived" => @agg.survived_count, "no_coverage" => @agg.no_coverage_count,
        "uncapturable" => @agg.uncapturable_count, "unplaceable" => @agg.unplaceable_count,
        "ran_at_load" => @agg.ran_at_load_count, "ignored" => @agg.ignored_count,
        "dropped" => dropped_count,
        "skipped" => @agg.skipped_invalid_count,
        "errored" => @agg.errored_count, "timeout" => @agg.timeout_count,
        "unpaired" => unpaired_mutant_count
      }
      if declined.any?
        label = scoped ? "declined (not narrowed by --since)" : "declined"
        counts[label] = declined.values.sum
      end
      if subjects && unmutated
        counts["no_mutants"] = unmutated
        counts["methods"] = subjects
      end
      spans = counts.map { |k, v| "<span><strong>#{v}</strong> #{esc(k)}</span>" }.join("\n  ")
      "<div class=\"counts\">\n  #{spans}\n</div>"
    end

    # The per-source breakdown table.
    def per_source_html(per_source)
      return "" if per_source.empty?

      rows = per_source.map do |h|
        score = h[:score].nil? ? "N/A" : "#{h[:score]}%"
        "<tr><td>#{esc(h[:file])}</td><td class=\"num\">#{score}</td>" \
          "<td class=\"num\">#{h[:killed]}</td><td class=\"num\">#{h[:survived]}</td>" \
          "<td class=\"num\">#{h[:no_coverage]}</td></tr>"
      end.join("\n  ")
      <<~HTML.chomp
        <h2>Per-source</h2>
        <table>
        <tr><th>File</th><th>Score</th><th>Killed</th><th>Survived</th><th>No coverage</th></tr>
          #{rows}
        </table>
      HTML
    end

    # The surviving-mutants list, each with subject, location, operator, stable
    # id, and a colorized diff. All text is HTML-escaped.
    def survivors_html(survivors)
      return "<h2>Surviving Mutants</h2>\n<p>None — every covered mutant was killed.</p>" if survivors.empty?

      cards = survivors.map do |s|
        diff_lines = s[:diff].each_line.map do |line|
          cls = line.start_with?("+") ? "add" : (line.start_with?("-") ? "del" : nil)
          text = esc(line.chomp)
          cls ? "<span class=\"#{cls}\">#{text}</span>" : text
        end.join("\n")
        <<~CARD.chomp
          <div class="survivor">
          <h3>#{esc(s[:subject])}</h3>
          <div class="meta">#{esc(s[:file])}:#{s[:line]} &middot; #{esc(s[:operator])} &middot; <span class="id">#{esc(s[:id])}</span></div>
          #{copies_html(s[:copies])}
          <pre class="diff">#{diff_lines}</pre>
          </div>
        CARD
      end.join("\n")
      "<h2>Surviving Mutants</h2>\n#{cards}"
    end

    # Ignored mutants, each with its id and its reason when the user gave one.
    #
    # @api private
    # @return [String] HTML, or "" when none were ignored.
    def ignored_html
      rows = @agg.results.select(&:ignored?).map { |r| ignored_json(r) }
                 .sort_by { |h| [h[:file], h[:line], h[:operator], h[:id].to_s] }
      return "" if rows.empty?

      cards = rows.map do |row|
        reason = row[:reason] ? "<div class=\"meta\">#{esc(row[:reason])}</div>" : ""
        <<~CARD.chomp
          <div class="survivor">
          <h3>#{esc(row[:subject])}</h3>
          <div class="meta">#{esc(row[:file])}:#{row[:line]} &middot; #{esc(row[:operator])} &middot; <span class="id">#{esc(row[:id])}</span></div>
          #{reason}
          #{copies_html(row[:copies])}
          </div>
        CARD
      end.join("\n")
      "<h2>Ignored mutants</h2>\n#{cards}"
    end

    # Errored mutants, each with its id and the cause the run recorded
    # (#480). The JSON report has the same rows under `no_verdict`.
    #
    # @api private
    # @return [String] HTML, or "" when no mutant errored.
    def errored_html
      rows = errored_rows
      return "" if rows.empty?

      cards = rows.map do |row|
        <<~CARD.chomp
          <div class="survivor">
          <h3>#{esc(row[:subject] || "unknown method")}</h3>
          <div class="meta">#{esc(errored_place(row))} &middot; #{esc(row[:operator].to_s)} &middot; <span class="id">#{esc(row[:id].to_s)}</span></div>
          <pre class="diff">#{esc(errored_cause(row))}</pre>
          </div>
        CARD
      end.join("\n")
      "<h2>Errored mutants</h2>\n#{cards}"
    end

    # The kill-matrix section of the HTML report: the counts, then the blind and
    # redundant tests. Empty without --matrix.
    #
    # @api private
    # @return [String] HTML.
    def matrix_html
      return "" unless @matrix

      lists = { "Blind tests" => @matrix.blind, "Redundant tests" => @matrix.redundant }.map do |title, tests|
        items = tests.map { |test| "<li><span class=\"id\">#{esc(test[0])}</span> #{esc(test_label(test))}</li>" }
        body = items.empty? ? "<p>None.</p>" : "<ul>\n#{items.join("\n")}\n</ul>"
        "<h3>#{esc(title)} (#{tests.size})</h3>\n#{body}"
      end
      note = @matrix.complete? ? "" : "\n<p>#{esc(matrix_incomplete_note)}</p>\n#{matrix_incomplete_html}"
      delete = @matrix.redundant.empty? ? "" : "\n<p>#{esc(MATRIX_REDUNDANT_NOTE)}</p>"
      "<h2>Kill matrix</h2>\n<p>#{esc(matrix_counts_line)}</p>#{note}\n#{lists.join("\n")}#{delete}"
    end

    # Every incomplete row of the HTML kill-matrix section.
    #
    # @api private
    # @return [String] HTML.
    def matrix_incomplete_html
      items = @matrix.incomplete_rows.map { |r| "<li>#{esc(matrix_row_label(r))}</li>" }
      "<h3>Incomplete rows (#{items.size})</h3>\n<ul>\n#{items.join("\n")}\n</ul>"
    end

    # The JSON `matrix` block: every test with its kill count, one row per
    # mutant that ran (its killers as indexes into `tests`), and the blind and
    # redundant tests. Rows sort like survivors, then by id, so output is
    # byte-stable regardless of --jobs.
    #
    # @api private
    # @return [Hash] the matrix JSON object.
    def matrix_json
      tests = @matrix.tests
      index = tests.each_with_index.to_h
      {
        complete: @matrix.complete?,
        tests: tests.map { |test| test_json(test).merge(kills: @matrix.kill_count(test)) },
        mutants: @matrix.rows.map { |r| matrix_row_json(r, index) }
                        .sort_by { |h| [h[:file].to_s, h[:line].to_i, h[:operator].to_s, h[:id].to_s] },
        blind: @matrix.blind.map { |test| test_json(test) },
        redundant: @matrix.redundant.map { |test| test_json(test) }
      }
    end

    # One test as JSON: its file, display name and id.
    #
    # @api private
    # @param test [Array(String, String, String)] a `[file, name, id]` test.
    # @return [Hash]
    def test_json(test)
      file, name, id = test
      { file: file, name: name, id: id }
    end

    # A test's name for people: the display name, plus the id when it differs
    # (an RSpec example id, which tells apart examples that share a name and
    # runs exactly that example with `rspec`).
    #
    # @api private
    # @param test [Array(String, String, String)] a `[file, name, id]` test.
    # @return [String]
    def test_label(test)
      _file, name, id = test
      id == name ? name : "#{name} (#{id})"
    end

    # One mutant's row under `matrix.mutants`.
    #
    # @api private
    # @param result [Mutineer::Result] a result with a {Kills} row.
    # @param index [Hash{Array => Integer}] test => its index in `matrix.tests`.
    # @return [Hash] the row JSON object.
    def matrix_row_json(result, index)
      file = result.subject&.file
      kills = result.kills
      {
        subject: result.subject&.qualified_name, file: file, line: result_line(result),
        operator: result.mutation&.operator&.to_s, id: result.id, status: result.status.to_s,
        killed_by: kills.killed_by.map { |test| index.fetch(test) }.sort,
        ran: kills.ran.size, complete: kills.complete
      }
    end

    # The kill-matrix section of the human report.
    #
    # @api private
    # @param out [IO] output stream.
    # @return [void]
    def matrix_section(out)
      out.puts
      out.puts "Kill matrix"
      out.puts "-----------"
      out.puts matrix_counts_line
      matrix_incomplete_section(out) unless @matrix.complete?
      matrix_list(out, "Blind tests (ran, killed no mutant)", @matrix.blind)
      matrix_list(out, "Redundant tests (each mutant they kill has another killer)", @matrix.redundant)
      return if @matrix.redundant.empty?

      out.puts MATRIX_REDUNDANT_NOTE
    end

    # The human report's warning about incomplete rows, with the first
    # {MATRIX_LIST_LIMIT} of them named.
    #
    # @api private
    # @param out [IO] output stream.
    # @return [void]
    def matrix_incomplete_section(out)
      rows = @matrix.incomplete_rows
      out.puts matrix_incomplete_note
      rows.first(MATRIX_LIST_LIMIT).each { |r| out.puts "  #{printable(matrix_row_label(r))}" }
      rest = rows.size - MATRIX_LIST_LIMIT
      out.puts "  and #{rest} more" if rest.positive?
      out.puts "The HTML and JSON reports list every incomplete row (JSON: matrix.mutants with complete: false)."
    end

    # A row's label: subject, place, operator, status and id.
    #
    # @api private
    # @param result [Mutineer::Result] a result with a {Kills} row.
    # @return [String]
    def matrix_row_label(result)
      place = [result.subject&.file, result_line(result)].compact.join(":")
      [result.subject&.qualified_name, ("(#{place})" unless place.empty?), result.mutation&.operator,
       result.status, result.id].compact.join(" ")
    end

    # The 1-based line of a result's mutation, or nil without one (a pre-fork
    # failure has no subject or mutation).
    #
    # @api private
    # @param result [Mutineer::Result] any result.
    # @return [Integer, nil]
    def result_line(result)
      file = result.subject&.file
      return unless result.mutation && file

      source = source_for(file)
      source.byteslice(0, result.mutation.start_offset).count("\n") + 1
    end

    # One titled list of tests in the human kill-matrix section, cut at
    # {MATRIX_LIST_LIMIT}; the JSON report has the whole list.
    #
    # @api private
    # @param out [IO] output stream.
    # @param title [String] the list's title.
    # @param tests [Array<Array(String, String, String)>] `[file, name, id]` tests.
    # @return [void]
    def matrix_list(out, title, tests)
      out.puts
      out.puts "#{title}: #{tests.size}"
      tests.first(MATRIX_LIST_LIMIT).each { |test| out.puts "  #{printable(test[0])}  #{printable(test_label(test))}" }
      rest = tests.size - MATRIX_LIST_LIMIT
      out.puts "  and #{rest} more; see --format json" if rest.positive?
    end

    # The counts sentence both matrix renderers open with.
    #
    # @api private
    # @return [String]
    def matrix_counts_line
      "#{@matrix.tests.size} tests ran against #{@matrix.rows.size} mutants " \
        "(every test in each mutant's covering files): " \
        "#{@matrix.blind.size} blind, #{@matrix.redundant.size} redundant."
    end

    # The warning both matrix renderers give when a row is incomplete.
    #
    # @api private
    # @return [String]
    def matrix_incomplete_note
      "#{@matrix.incomplete_rows.size} mutants could not be verified as complete (a timeout, an error, " \
        "an exit, an interrupt or a broken stream), so a blind test may have killed one of them. " \
        "Do not delete a blind test until these rows are complete:"
    end

    # HTML-escapes any text destined for the document (stdlib CGI).
    def esc(text) = CGI.escapeHTML(utf8_text(text))

    # The same delta facts the human report prints, for dashboards. new_survivors
    # reuse the mutant_json shape (subject/file/line/operator/token/id) and sort
    # byte-stably so output does not depend on --jobs finish order.
    def baseline_json(delta)
      {
        regressed: delta.regressed,
        # Additive (2.0, #283): the run fails the completeness rule; --baseline exits 1.
        incomplete: delta.incomplete,
        score_before: delta.score_before,
        score_after: delta.score_after,
        score_dropped: delta.score_drop,
        # Additive: false when the score-drop check was skipped (a nil score or
        # a diff-scoped side), so a consumer knows not to render the two scores
        # as a comparison.
        score_comparable: delta.score_comparable,
        new_survivors: delta.new_survivors.map { |r| mutant_json(r) }
                            .sort_by { |h| [h[:file], h[:line], h[:operator], h[:id].to_s] },
        fixed_survivors: delta.fixed_survivors.map do |h|
          { subject: h["subject"], file: h["file"], line: h["line"],
            operator: h["operator"], id: h["id"] }
        end.sort_by { |h| [h[:file].to_s, h[:line].to_i, h[:operator].to_s] },
        # Additive (2.0, #283, #286): stored survivors this run did not decide.
        unverified_survivors: delta.unverified_survivors.map do |h|
          { subject: h["subject"], file: h["file"], line: h["line"],
            operator: h["operator"], id: h["id"], status: h["status"] }
        end.sort_by { |h| [h[:file].to_s, h[:line].to_i, h[:operator].to_s, h[:id].to_s] }
      }
    end

    # Builds per-source JSON.
    #
    # @api private
    # @param file [String] source file path.
    # @param agg [Mutineer::AggregateResult] source aggregate.
    # @return [Hash] per-source JSON object.
    def per_source_json(file, agg)
      {
        file: file, total: agg.total,
        killed: agg.killed_count, survived: agg.survived_count,
        no_coverage: agg.no_coverage_count, score: agg.mutation_score
      }
    end

    # The callback growth rows as `{ class, file }` objects, sorted by file
    # and class: the runner returns them in worker finish order, and the
    # report must stay byte-stable. {#json_safe} makes the strings UTF-8.
    #
    # @api private
    # @return [Array<Hash>, nil] nil when the caller gave no rows.
    def callback_growth_json
      @callback_growth&.map { |name, file| { class: name, file: file } }
                      &.sort_by { |h| [h[:file], h[:class]] }
    end

    # Builds survivor JSON.
    #
    # @api private
    # @param result [Mutineer::Result] survivor result.
    # @return [Hash] survivor JSON object.
    def survivor_json(result)
      m = result.mutation
      file = result.subject.file
      start_line, _orig, _mut, token = diff_for(m, source_for(file))
      row = {
        subject: utf8_text(result.subject.qualified_name.to_s),
        file: file,
        line: start_line,
        operator: m.operator.to_s,
        # The stable, copy-pasteable id (next to the human-readable token) so a
        # user can paste it straight into .mutineer.yml `ignore:`.
        id: result.id,
        token: utf8_text(token),
        diff: unified_diff(result),
        # Additive (1.11, #495): the run step's wall-clock seconds.
        seconds: result.seconds&.round(3)
      }
      attach_diff(row, result)
      attach_copies(row, result.id)
    end

    # A lean mutant row plus the same `diff` a survivor gets (#498): for the
    # killed, unplaceable and ran-at-load lists, whose consumers act on the change.
    #
    # @api private
    # @param result [Mutineer::Result] the mutant result.
    # @param seconds [Boolean] also add `seconds` (#495), for `killed`.
    # @return [Hash] {#mutant_json} with `diff`; `diff` is nil when the result
    #   has no subject or mutation.
    def mutant_with_diff_json(result, seconds: false)
      row = mutant_json(result)
      copies = row.delete(:copies)
      row[:diff] = unified_diff(result)
      attach_diff(row, result)
      row[:seconds] = result.seconds&.round(3) if seconds
      row[:copies] = copies if copies
      row
    end

    # Adds the diff keys that depend on the source to a row that has `diff`.
    # The diff is UTF-8, as JSON is, so `diff_encoding` names the source's
    # encoding when a consumer can transcode the hunk lines back to the file's
    # bytes (#510), and `diff_base64` holds the exact patch whenever the bytes
    # of `diff` are not that patch (#518). Both are withheld when the change
    # may hold a credential that redaction would hide ({#credential_free?}). Each caller sets `diff` itself, so
    # each list keeps its own key order.
    #
    # @api private
    # @param row [Hash] one mutant's JSON object, with `diff` set.
    # @param result [Mutineer::Result] the mutant result.
    # @return [Hash] `row`.
    def attach_diff(row, result)
      return row unless row[:diff]

      encoding = result_diff_encoding(result)
      patch = exact_patch(result)
      # #518: the exact bytes when the text is not the patch for the file.
      # pack("m0"), not the base64 library, which is a bundled gem since Ruby 3.4.
      base64 = [patch].pack("m0") if patch && patch.b != row[:diff].b
      return row unless encoding || base64
      # Both keys give a consumer the file's bytes, past the stdout redaction
      # that hides a credential in `diff`. Withhold both when in doubt (#540).
      return row unless credential_free?(row[:diff], patch)

      row[:diff_encoding] = encoding if encoding
      row[:diff_base64] = base64 if base64
      row
    end

    # True when the change can be shown as bytes with no credential in it:
    # redaction alters neither `diff` nor the patch bytes read as UTF-8, and,
    # when a credential is configured, those bytes are valid UTF-8, so the
    # check could read them. Fails closed (#540).
    #
    # @api private
    # @param diff [String] the UTF-8 diff.
    # @param patch [String] the exact byte patch.
    # @return [Boolean]
    def credential_free?(diff, patch)
      bytes = patch.b.force_encoding(Encoding::UTF_8)
      return false if !bytes.valid_encoding? && Redaction.source_urls(ENV, []).any?

      [diff, bytes.scrub].all? { |text| Redaction.text(text) == text }
    end

    # The unified diff of one mutant, with no context lines.
    #
    # @api private
    # @param result [Mutineer::Result] the mutant result.
    # @return [String, nil] the diff, or nil when the result has no subject or
    #   mutation (a stub result).
    def unified_diff(result)
      build_patch(result) { |piece| utf8_text(piece) }
    end

    # The same patch as {#unified_diff}, with each side line in the file's own
    # bytes (#518), so `git apply` accepts it for any source encoding. The
    # path keeps the UTF-8 text `diff` shows (#532).
    #
    # @api private
    # @param result [Mutineer::Result] the mutant result.
    # @return [String, nil] the patch, or nil when the result has no subject
    #   or mutation.
    def exact_patch(result)
      build_patch(result, &:b)
    end

    # The one builder of both patches, so the header, the hunk ranges and the
    # end-of-file rule cannot drift apart. `piece` turns the path and each
    # side line into the text the patch holds.
    #
    # @api private
    # @param result [Mutineer::Result] the mutant result.
    # @yieldparam piece [String] the path or one side line.
    # @yieldreturn [String] its form in the patch.
    # @return [String, nil] the patch, or nil when the result has no subject
    #   or mutation (a stub result).
    def build_patch(result, &piece)
      m = result.mutation
      return nil if result.subject.nil? || m.nil?

      file = result.subject.file
      source = source_for(file)
      start_line, original_block, mutated_block, = diff_for(m, source)
      # A block at the end of the file has no newline after it; elsewhere the
      # file's next byte is one. Each side's own text decides its marker.
      at_eof = source.byteindex("\n", m.end_offset).nil?
      old_lines = side_lines(original_block, at_eof).map(&piece)
      new_lines = side_lines(mutated_block, at_eof).map(&piece)
      # The path stays the text `diff` shows, so only the side lines differ (#532).
      shown_file = piece.call(utf8_text(file))
      "--- a/#{shown_file}\n+++ b/#{shown_file}\n" \
        "@@ -#{hunk_range(start_line, old_lines)} +#{hunk_range(start_line, new_lines)} @@\n" \
        "#{diff_body("-", old_lines)}#{diff_body("+", new_lines)}"
    end

    # The encoding {#diff_encoding} names for a result's diff, or nil when the
    # result has no subject or mutation (a stub result) or needs none.
    #
    # @api private
    # @param result [Mutineer::Result] the mutant result.
    # @return [String, nil] the Ruby encoding name, e.g. "EUC-JP".
    def result_diff_encoding(result)
      m = result.mutation
      return nil if result.subject.nil? || m.nil?

      source = source_for(result.subject.file)
      _line, original_block, mutated_block, = diff_for(m, source)
      diff_encoding(source, original_block, mutated_block)
    end

    # The encoding the {#survivor_json} diff was transcoded from: the source's
    # own, when it is valid and not UTF-8. Nil for a UTF-8 source, which needs
    # no transcoding, for a binary one, whose bytes {#utf8_text} reads as UTF-8,
    # for an invalid one, whose bad bytes print as `\xNN` and cannot be restored,
    # and when a block does not convert back to its own bytes (CP932 0xFA4A
    # reads as U+2160, which encodes back as 0x8754), so a consumer could not
    # restore the line. Those rows carry `diff_base64` instead (#518).
    #
    # @api private
    # @param source [String] source text, tagged with its encoding.
    # @param blocks [Array<String>] the original and mutated blocks of the diff.
    # @return [String, nil] the Ruby encoding name, e.g. "EUC-JP".
    def diff_encoding(source, *blocks)
      enc = source.encoding
      return nil if [Encoding::UTF_8, Encoding::US_ASCII, Encoding::BINARY].include?(enc) || !source.valid_encoding?
      return nil unless blocks.all? { |b| b.encode(Encoding::UTF_8).encode(enc).b == b.b }

      enc.name
    rescue EncodingError
      nil
    end

    # One side of the diff as the file holds it: the {#diff_for} block plus the
    # newline that follows it, unless the block ends the file. Each line keeps
    # its own ending, so a CRLF line keeps its "\r" and a last line with no
    # newline is told apart from one with a newline. The lines stay in the
    # source's encoding; {#build_patch} converts them.
    #
    # @api private
    # @param block [String] the block's text.
    # @param at_eof [Boolean] no newline follows the block in the file.
    # @return [Array<String>] its lines, with their endings.
    def side_lines(block, at_eof)
      newline = "\n".dup.force_encoding(block.encoding)
      text = at_eof ? block : block + newline
      text.lines
    end

    # The `-` or `+` lines of one side. A line with no newline is the file's
    # last, so it gets the unified diff's no-newline marker (#106).
    #
    # @api private
    # @param sign [String] "-" or "+".
    # @param lines [Array<String>] the side's lines, with their endings.
    # @return [String]
    def diff_body(sign, lines)
      lines.map { |l| l.end_with?("\n") ? "#{sign}#{l}" : "#{sign}#{l}\n\\ No newline at end of file\n" }.join
    end

    # One side of a unified diff hunk header: `start` for one line, else
    # `start,count`; an empty side is `start-1,0` (#106).
    #
    # @api private
    # @param start_line [Integer] 1-based first line of the block.
    # @param lines [Array<String>] the block's lines.
    # @return [String] the range, e.g. "3", "3,2" or "2,0".
    def hunk_range(start_line, lines)
      return "#{start_line - 1},0" if lines.empty? # an empty side names the line before it

      lines.size == 1 ? start_line.to_s : "#{start_line},#{lines.size}"
    end

    # One ignored mutant. `reason` is present only when the user wrote one.
    #
    # @api private
    # @param result [Mutineer::Result] an ignored result.
    # @return [Hash]
    def ignored_json(result)
      row = mutant_json(result)
      text = result.reason
      row[:reason] = text if text.is_a?(String) && !text.strip.empty?
      row
    end

    # The fields that name one mutant, for the lists that point at mutants:
    # `no_coverage`, `uncapturable`, `ignored` and `baseline.new_survivors`,
    # and the base of `killed`, `unplaceable` and `ran_at_load`
    # ({#mutant_with_diff_json}).
    #
    # @api private
    # @param result [Mutineer::Result] the mutant result.
    # @return [Hash] subject, file, line, operator, token, and id.
    def mutant_json(result)
      lean_mutant_json(result.subject, result.mutation, result.id)
    end

    # Lean mutant identity shared by run-report lists and `--dry-run --format json`.
    #
    # @api private
    # @param subject [Mutineer::Subject] the mutated subject.
    # @param mutation [Mutineer::Mutation] the mutation.
    # @param id [String, nil] the stable mutant id.
    # @return [Hash] subject, file, line, operator, token, and id.
    def lean_mutant_json(subject, mutation, id)
      # Stub results in tests (and rare pre-attach kills) can lack a subject.
      # Match no_verdict_json: null fields rather than raising.
      if subject.nil? || mutation.nil?
        return attach_copies({
          subject: nil, file: nil, line: nil, operator: nil, token: nil, id: id
        }, id)
      end

      file = subject.file
      source = source_for(file)
      start_line, _orig, _mut, token = diff_for(mutation, source)
      attach_copies({
        subject: subject.qualified_name,
        file: file,
        line: start_line,
        operator: mutation.operator.to_s,
        token: token,
        id: id
      }, id)
    end

    # JSON for `--dry-run --format json`: every valid candidate with its stable
    # id, plus summary totals. Ids match a later real run of the same JobPlan.
    # Callers partition with {Mutation#valid?} once and pass only valid jobs;
    # this method does not re-validate.
    #
    # @param jobs [Array<Array>] valid `(subject, mutation, id)` triples from
    #   {JobPlan.collect_jobs} (after {JobPlan.scope_since}).
    # @param source_map [Hash{String => String}] source file path => source text.
    # @param declined [Hash{String => Integer}] operator name => declined count.
    # @param skipped_invalid [Integer] candidates that did not re-parse.
    # @param ignored [Integer] suppressed candidates.
    # @param unmatched_ignores [Array<String>] `ignore:` ids that matched no
    #   mutant (#377), the same list a real run records.
    # @param copies [Hash{String => Array<String>}] kept id => dropped repeat
    #   ids (#374). Each listed mutant gains `copies` when it has any.
    #   `summary.dropped` counts every id in `copies`, including a repeat of
    #   an ignored mutant, which this document does not list.
    # @return [String] JSON text.
    def self.dry_run_json(jobs, source_map, declined: {}, skipped_invalid: 0, ignored: 0,
                          unmatched_ignores: [], copies: {})
      reporter = new(AggregateResult.new([]), source_map)
      reporter.send(:apply_copies, copies)
      by_operator = Hash.new(0)
      mutants = jobs.map do |subject, mutation, id|
        by_operator[mutation.operator.to_s] += 1
        reporter.__send__(:lean_mutant_json, subject, mutation, id)
      end
      mutants.sort_by! { |h| [h[:file].to_s, h[:line].to_i, h[:operator].to_s, h[:id].to_s] }
      doc = {
        schema_version: SCHEMA_VERSION,
        summary: {
          # Same marker as a completed report: absent means the old id format.
          id_format: 2,
          total: mutants.size,
          skipped_invalid: skipped_invalid,
          ignored: ignored,
          # Same list as a completed report (#377). Absent means an older dry run.
          unmatched_ignores: unmatched_ignores,
          dropped: dropped_count_for(copies),
          declined: declined.values.sum,
          declined_by_operator: declined,
          by_operator: by_operator.sort.to_h
        },
        mutants: mutants
      }
      "#{JSON.generate(reporter.__send__(:json_safe, doc))}\n"
    end

    # Builds a line-aligned diff for a mutation whose byte range may span several
    # lines (e.g. statement-removal of a multi-line statement). Returns the
    # mutation's 1-based start line, the full original line-block it touches, the
    # spliced mutated block, and a single-line token label for the header.
    def diff_for(m, source)
      # Byte math: Prism offsets are byte offsets; byteindex/byterindex/
      # byteslice keep line splicing correct for multibyte sources.
      line_begin = m.start_offset.zero? ? 0 : (source.byterindex("\n", m.start_offset - 1) || -1) + 1
      line_end   = source.byteindex("\n", m.end_offset) || source.bytesize
      before = source.byteslice(line_begin...m.start_offset)
      after  = source.byteslice(m.end_offset...line_end)
      original_block = source.byteslice(line_begin...line_end)
      replacement = m.replacement
      replacement = replacement.dup.force_encoding(before.encoding) if replacement.ascii_only?
      mutated_block = before + replacement + after
      start_line  = source.byteslice(0, m.start_offset).count("\n") + 1
      token       = source.byteslice(m.start_offset...m.end_offset).gsub(/\s+/, " ").strip
      if token.length > 50
        token = token[0, 47] + "...".dup.force_encoding(token.encoding)
      end
      [start_line, original_block, mutated_block, token]
    end

    # An entry under the JSON `no_verdict:` key: an attempted mutant with no verdict.
    # A pre-fork failure has no subject or mutation attached, so those degrade to
    # nulls rather than dropping the entry — the count must still reconcile with
    # `summary.no_verdict`. `details` is redacted here too, whatever its source
    # (#388). `diff` is the text a survivor gets (#526), and null with no
    # mutation.
    #
    # @api private
    # @param result [Mutineer::Result] an errored, timed-out or uncapturable result.
    # @return [Hash] no-verdict JSON object.
    def no_verdict_json(result)
      file = result.subject&.file
      # As in result_line: diff_for needs the source, so a mutation needs a file.
      m = result.mutation if file
      line, _orig, _mut, token = diff_for(m, source_for(file)) if m
      row = {
        subject: result.subject&.qualified_name,
        file: file,
        line: line,
        operator: m&.operator&.to_s,
        token: token,
        id: result.id,
        status: result.status.to_s,
        details: result.details && Redaction.text(result.details),
        # Additive (1.11, #526): the diff, as on survivors, so a consumer can
        # run the mutant again itself. Null with no mutation to show.
        diff: (unified_diff(result) if m)
      }
      attach_diff(row, result)
      row[:seconds] = result.seconds&.round(3)
      attach_copies(row, result.id)
    end

    # Adds `copies` when this mutant has dropped repeats (#374). Absent when
    # it has none, so a report with no repeats keeps the previous keys.
    #
    # @api private
    # @param row [Hash] one mutant's JSON object.
    # @param id [String, nil] the kept mutant's id.
    # @return [Hash] `row`.
    def attach_copies(row, id)
      list = @copies[id] if id
      row[:copies] = list if list&.any?
      row
    end

    # Stores the copy map for a reporter built outside {#report}, such as the
    # dry-run document.
    #
    # @api private
    # @param copies [Hash, nil] kept id => dropped ids.
    # @return [void]
    def apply_copies(copies)
      @copies = copies || {}
    end

    # Dropped repeats of mutants this report lists. A skipped mutant has no
    # row, so its repeats are not counted. `--fail-fast` omits unscheduled
    # mutants, and their repeats with them.
    #
    # @api private
    # @return [Integer]
    def dropped_count
      @agg.results.sum do |result|
        next 0 if result.skipped? || result.id.nil?

        @copies[result.id]&.size || 0
      end
    end

    # The copy lists for `ids`, or every list when `ids` is nil.
    #
    # @param copies [Hash, nil] kept id => dropped ids.
    # @param ids [Array<String>, nil] kept ids to keep.
    # @return [Hash{String => Array<String>}]
    def self.copies_for(copies, ids = nil)
      map = copies || {}
      return map if ids.nil?

      wanted = ids.to_set
      map.select { |id, _list| wanted.include?(id) }
    end

    # How many dropped ids `copies` holds. With `ids`, only those kept mutants.
    #
    # @param copies [Hash, nil] kept id => dropped ids.
    # @param ids [Array<String>, nil] kept ids to count; nil counts every list.
    # @return [Integer]
    def self.dropped_count_for(copies, ids = nil)
      copies_for(copies, ids).each_value.sum { |list| Array(list).size }
    end

    # The HTML line of dropped-copy ids, or "" when there are none.
    #
    # @api private
    # @param copies [Array<String>, nil]
    # @return [String]
    def copies_html(copies)
      return "" if copies.nil? || copies.empty?

      ids = copies.map { |id| "<span class=\"id\">#{esc(id)}</span>" }.join(", ")
      "<div class=\"meta\">copies #{ids}</div>"
    end

    # Writes the summary block.
    #
    # @param out [IO] output stream.
    # @param declined [Hash{String => Integer}] operator name => declined count.
    # @param scoped [Boolean] the run was diff-scoped (`--since`), which does not
    #   narrow the declined count (method counts are already narrowed by
    #   {JobPlan.scope_since}, #420).
    # @param subjects [Integer, nil] methods discovered; nil when unknown.
    # @param unmutated [Integer, nil] methods the selected operators did not
    #   mutate; nil when unknown, which leaves out the `No mutants:` row.
    # @return [void]
    def summary(out, declined: {}, scoped: false, subjects: nil, unmutated: nil)
      out.puts "Summary"
      out.puts "-------"
      out.puts format("Total:        %-6d  Killed:        %d", @agg.total, @agg.killed_count)
      out.puts format("Survived:     %-6d  No coverage:   %d", @agg.survived_count, @agg.no_coverage_count)
      out.puts format("Skipped:      %-6d  Errored:       %d", @agg.skipped_invalid_count, @agg.errored_count)
      out.puts format("Timeout:      %-6d  (over the per-mutant time limit)", @agg.timeout_count)
      # A broken harness, not a coverage gap: report it distinctly from No coverage.
      out.puts format("Uncapturable: %-6d  (tests failed to run)", @agg.uncapturable_count)
      # Not broken: the strategy cannot load these where the tests call them (no
      # named class under redefine, or some methods in a concern's `included` or
      # `prepended` block; see docs/json-schema.md).
      out.puts format("Unplaceable:  %-6d  (not loadable where the tests call it; verify with --test-command)",
                      @agg.unplaceable_count)
      # Not a verdict: the line ran before the mutant was applied (#187).
      out.puts format("Ran at load:  %-6d  (ran while the app or class loaded; mutineer cannot re-run that; " \
                      "verify with --test-command)", @agg.ran_at_load_count)
      # Not mutants: candidates an operator chose not to mutate (#291).
      out.puts format("Declined:     %-6d  (candidates an operator did not mutate; --dry-run shows the count " \
                      "per operator%s)", declined.values.sum, scoped ? "; not narrowed by --since" : "")
      # Not mutants: methods, which no operator gave a mutant (#386). Unknown
      # (a caller passed no method counts) prints no row, never a made-up 0.
      if subjects && unmutated
        # Under --since the JobPlan already narrowed these counts (#420).
        out.puts format("No mutants:   %-6d  (methods of %d that the selected operators did not mutate; " \
                        "--dry-run --verbose and the JSON report list them)",
                        unmutated, subjects)
      end
      # Equivalent mutants the user suppressed; excluded from the denominator.
      out.puts format("Ignored:      %-6d  (equivalent, suppressed)", @agg.ignored_count)
      # Repeats that were not run (#374). The ids are on `copies` in the JSON.
      out.puts format("Dropped:      %-6d  (repeats of a kept mutant; see --format json)", dropped_count)
      out.puts unpaired_line(scoped)
      out.puts time_line if @timing
    end

    # The human `Time:` line (#495): total seconds, then each phase, `n/a` for
    # a phase the run did not have.
    #
    # @api private
    # @return [String]
    def time_line
      phase = ->(key) { (v = @timing[key]) ? format("%.3fs", v) : "n/a" }
      format("Time:         %-6s  (boot %s, coverage %s, clean check %s, mutants %s; phases do not add up to the total)",
             phase.call(:total_seconds), phase.call(:boot_seconds), phase.call(:coverage_seconds),
             phase.call(:clean_check_seconds), phase.call(:mutants_seconds))
    end

    # Writes the score line.
    #
    # @param out [IO] output stream.
    # @param err [IO] error stream.
    # @return [void]
    def score_line(out, err)
      score = @agg.mutation_score
      excluded = "#{@agg.no_coverage_count} no-coverage, #{@agg.uncapturable_count} uncapturable, " \
                 "#{@agg.unplaceable_count} unplaceable, #{@agg.ran_at_load_count} ran at load, " \
                 "#{@agg.skipped_invalid_count} skipped, " \
                 "#{@agg.errored_count} errored, #{@agg.timeout_count} timeout, " \
                 "#{unpaired_mutant_count} unpaired, #{@agg.ignored_count} ignored excluded"
      if score.nil?
        out.puts "Mutation score: N/A  (no covered mutants)"
        # Only the benign case here: the gate-failure explanation is emitted once
        # from {report}, for every format, so it cannot be said twice or only to
        # the reader of the human report.
        unless @agg.broken_nil_score?
          err.puts "[mutineer] no covered mutations; mutation score is N/A and the threshold check is skipped."
        end
      else
        out.puts "Mutation score: #{score}%  (killed / (killed + survived); #{excluded})"
      end
    end

    # Whether the unrun mutants are more than {BROKEN_FLOOR} and more than
    # {UNRUN_SHARE_LIMIT} of attempted plus unrun. A run with no result rows
    # does not warn here. The empty-run message owns that case.
    #
    # @api private
    # @return [Boolean] true when the unrun-share warning applies.
    def unrun_share_exceeded?
      return false if @agg.total.zero?

      unrun = unrun_for_share
      unrun > BROKEN_FLOOR && unrun > UNRUN_SHARE_LIMIT * (@agg.attempted_count + unrun)
    end

    # Unrun mutants in the share. `--fail-fast` leaves unpaired mutants out.
    #
    # @api private
    # @return [Integer]
    def unrun_for_share
      return @agg.unrun_count unless unpaired_in_share?

      @agg.unrun_count + unpaired_mutant_count
    end

    # True when unpaired mutants join the unrun share and the human percentage.
    # A failed count is not in the sum, so it does not join on its own.
    #
    # @api private
    # @return [Boolean]
    def unpaired_in_share?
      !@fail_fast && !@agg.total.zero? && unpaired_mutant_count.positive?
    end

    # Known unpaired mutant counts. A nil count is left out.
    #
    # @api private
    # @return [Integer]
    def unpaired_mutant_count
      @unpaired.each_value.sum { |count| count.is_a?(Integer) ? count : 0 }
    end

    # `unpaired_sources[]` sorted by file. A nil count stays nil, so JSON writes null.
    #
    # @api private
    # @return [Array<Hash>]
    def unpaired_sources_json
      @unpaired.map { |file, count| { file: file, mutants: count } }.sort_by { |row| row[:file].to_s }
    end

    # The human Unpaired line. The percentage is omitted under `--fail-fast`,
    # when the denominator is empty, and when the mutant count is 0.
    #
    # @api private
    # @param scoped [Boolean] the run was diff-scoped (`--since`).
    # @return [String]
    def unpaired_line(scoped)
      detail = [scoped ? "mutants on changed lines not run" : "mutants not run"]
      sources = @unpaired.size
      detail << (sources == 1 ? "1 source has no paired test" : "#{sources} sources have no paired test")
      unknown = @unpaired.count { |_file, count| count.nil? }
      if unknown == 1
        detail << "1 source not counted"
      elsif unknown > 1
        detail << "#{unknown} sources not counted"
      end
      share = unpaired_scope_share
      detail << "#{share}% of the mutants in scope" if share
      format("Unpaired:     %-6d  (%s)", unpaired_mutant_count, detail.join("; "))
    end

    # Unpaired mutants over the scope denominator.
    # The denominator is `total - ignored + unpaired`. nil when it must be omitted.
    #
    # @api private
    # @return [Float, nil]
    def unpaired_scope_share
      return if @fail_fast

      count = unpaired_mutant_count
      return if count.zero?

      denominator = @agg.total - @agg.ignored_count + count
      return if denominator <= 0

      (count * 100.0 / denominator).round(1)
    end

    # The HTML table of sources with no paired test. Empty when none were skipped.
    #
    # @api private
    # @return [String]
    def unpaired_html
      return "" if @unpaired.empty?

      rows = @unpaired.sort_by { |file, _count| file.to_s }.map do |file, count|
        shown = count.nil? ? "unknown" : count.to_s
        "<tr><td>#{esc(file)}</td><td class=\"num\">#{esc(shown)}</td></tr>"
      end.join("\n  ")
      <<~HTML.chomp
        <h2>Sources with no paired test</h2>
        <table>
        <tr><th>File</th><th>Mutants</th></tr>
          #{rows}
        </table>
      HTML
    end

    # The sentence both the verdict line and the stderr note are built from, so a
    # user cannot read one number in the report and a different one beside it.
    #
    # @api private
    # @return [String] e.g. "90 of 100 attempted mutants produced no verdict (90.0%, limit 10%)".
    def no_verdict_ratio
      no_verdict = @agg.no_verdict_count
      attempted = @agg.attempted_count
      pct = (no_verdict * 100.0 / attempted).round(1)
      "#{no_verdict} of #{attempted} attempted mutants produced no verdict " \
        "(#{pct}%, limit #{(AggregateResult::BROKEN_SHARE_LIMIT * 100).round}%)"
    end

    # Human-readable counts of the states that produced no verdict. Used by both
    # the nil-score message and the completeness gate, so they agree.
    #
    # @api private
    # @return [String]
    def broken_counts_detail
      parts = []
      parts << "#{@agg.errored_count} errored" if @agg.errored_count.positive?
      parts << "#{@agg.timeout_count} timeout" if @agg.timeout_count.positive?
      parts << "#{@agg.uncapturable_count} uncapturable" if @agg.uncapturable_count.positive?
      parts.join(", ")
    end

    # One line per source after the global summary, so a multi-source run shows
    # which file is weak. Omitted for a single-source run: the global summary
    # already says everything (no redundant one-line block).
    #
    # @param out [IO] output stream.
    # @return [void]
    def per_source(out)
      sources = @agg.by_source
      return if sources.size <= 1

      out.puts
      out.puts "Per-source"
      out.puts "----------"
      sources.sort.each do |file, agg|
        score = agg.mutation_score
        out.puts format("%s  %s  (%d killed / %d survived / %d no-cov)",
                        printable(file), score.nil? ? "N/A" : "#{score}%",
                        agg.killed_count, agg.survived_count, agg.no_coverage_count)
      end
    end

    # The --baseline delta, appended after the normal report. Names every NEW
    # survivor (subject (file:line) operator), every unverified baseline
    # survivor, the score delta when it dropped and an incomplete run, then a
    # one-line REGRESSION/INCOMPLETE/OK verdict so CI logs show which gate fired.
    def baseline_section(out, delta)
      out.puts
      out.puts "Baseline comparison"
      out.puts "-------------------"
      out.puts "killed #{@agg.killed_count}, #{delta.new_survivors.size} new survivors vs baseline"
      delta.new_survivors
           .sort_by { |r| [r.subject.file, *tie_key(r)] }
           .each do |r|
        file = r.subject.file
        source = source_for(file)
        line, = diff_for(r.mutation, source)
        out.puts "  + #{printable(r.subject.qualified_name)} (#{printable(file)}:#{line}) #{r.mutation.operator}"
      end
      unverified_lines(out, delta.unverified_survivors)
      if delta.incomplete
        # The same facts as the stderr note in {#report}.
        detail = @agg.broken_nil_score? ? "nothing could be scored (#{broken_counts_detail})" : no_verdict_ratio
        out.puts "incomplete run: #{detail}"
      end
      if delta.score_drop
        # The check uses the exact counts (#343); the rounded values can be equal.
        hidden = delta.score_before == delta.score_after ? " (less than the rounding shows; the check uses the exact counts)" : ""
        out.puts "score dropped #{delta.score_before}% -> #{delta.score_after}%#{hidden}"
      end
      # An OK verdict must not imply a check that never ran: say when the score
      # comparison was skipped (a diff-scoped side or a nil score).
      out.puts "score-drop check skipped (scores not comparable)" unless delta.score_comparable
      out.puts baseline_verdict(delta)
    end

    # The last line of the baseline section: which gate failed, if any.
    #
    # @api private
    # @param delta [Mutineer::Baseline::Delta] baseline delta.
    # @return [String]
    def baseline_verdict(delta)
      # An incomplete run's score covers only part of it, so say so beside a regression.
      return "REGRESSION and INCOMPLETE vs baseline (read no_verdict[] first)" if delta.regressed && delta.incomplete
      return "REGRESSION vs baseline" if delta.regressed
      return "INCOMPLETE vs baseline (nothing could be scored; see no_verdict[])" if delta.incomplete && @agg.broken_nil_score?
      return "INCOMPLETE vs baseline (too many mutants produced no verdict; see no_verdict[])" if delta.incomplete

      "OK: no regression vs baseline"
    end

    # The baseline survivors this run did not decide, at most MATRIX_LIST_LIMIT
    # of them. Each stored field goes through `to_s` first: a hand-edited
    # baseline can lack one.
    #
    # @api private
    # @param out [IO] output stream.
    # @param entries [Array<Hash>] Delta#unverified_survivors.
    # @return [void]
    def unverified_lines(out, entries)
      return if entries.empty?

      out.puts "#{entries.size} baseline #{entries.size == 1 ? 'survivor' : 'survivors'} not decided this run " \
               "(not killed, survived or ignored), so not counted as fixed:"
      entries.sort_by { |h| [h["file"].to_s, h["line"].to_i, h["operator"].to_s, h["id"].to_s] }
             .first(MATRIX_LIST_LIMIT).each do |h|
        subject, file, line, operator, status = h.values_at("subject", "file", "line", "operator", "status").map(&:to_s)
        out.puts "  ? #{printable(subject)} (#{printable(file)}:#{printable(line)}) #{printable(operator)} " \
                 "[#{printable(status)}]"
      end
      rest = entries.size - MATRIX_LIST_LIMIT
      out.puts "  and #{rest} more (see baseline.unverified_survivors in --format json)" if rest.positive?
    end

    # Orders mutants in one file: by offset, then operator and replacement, so
    # mutants at the same offset list the same way whatever order they ran in.
    #
    # @param result [Mutineer::Result] a result with a mutation.
    # @return [Array] the sort key.
    def tie_key(result)
      m = result.mutation
      [m.start_offset, m.operator.to_s, m.replacement.to_s]
    end

    # Writes the survivors block.
    #
    # @param out [IO] output stream.
    # @return [void]
    def survivors(out)
      mutants = @agg.surviving_mutants
      return if mutants.empty?

      out.puts
      out.puts "Surviving Mutants"
      out.puts "-----------------"
      mutants.group_by { |r| r.subject.file }.sort.each do |file, group|
        out.puts
        out.puts printable(file)
        group.sort_by { |r| tie_key(r) }.each { |r| survivor(out, file, r) }
      end
    end

    # Writes the errored-mutants block: one entry per errored mutant, with
    # the cause the run recorded (#480). Only with `--verbose`.
    #
    # @api private
    # @param out [IO] output stream.
    # @return [void]
    def errored(out)
      rows = errored_rows
      return if rows.empty?

      out.puts
      out.puts "Errored Mutants"
      out.puts "---------------"
      rows.each do |row|
        head = "#{printable(row[:subject] || 'unknown method')} (#{printable(errored_place(row))})"
        out.puts "  #{[head, row[:operator], row[:id]].compact.join(' ')}"
        out.puts "    #{printable(errored_cause(row))}"
      end
    end

    # The errored mutants as {#no_verdict_json} rows, in file and line order.
    #
    # @api private
    # @return [Array<Hash>]
    def errored_rows
      @agg.results.select(&:error?).map { |r| no_verdict_json(r) }
          .sort_by { |h| [h[:file].to_s, h[:line].to_i, h[:operator].to_s, h[:id].to_s] }
    end

    # The cause of an errored row, or {ERRORED_NO_CAUSE} when it has none.
    # An empty `details` counts as none.
    #
    # @api private
    # @param row [Hash] one {#errored_rows} row.
    # @return [String]
    def errored_cause(row)
      text = row[:details].to_s
      text.strip.empty? ? ERRORED_NO_CAUSE : text
    end

    # `file:line` of an errored row, or a note when the error came before a
    # mutant was placed.
    #
    # @api private
    # @param row [Hash] one {#errored_rows} row.
    # @return [String]
    def errored_place(row)
      row[:file] ? "#{row[:file]}:#{row[:line]}" : "no mutant location"
    end

    # Writes one survivor entry.
    #
    # @param out [IO] output stream.
    # @param file [String] source file path.
    # @param result [Mutineer::Result] survivor result.
    # @return [void]
    def survivor(out, file, result)
      m = result.mutation
      source = source_for(file)
      start_line, original_block, mutated_block, token = diff_for(m, source)

      out.puts "  #{printable(result.subject.qualified_name)} (#{printable(File.basename(file))}:#{start_line})"
      out.puts "  Operator: #{m.operator}  (#{printable(token)} -> #{printable(m.replacement)})"
      original_block.each_line { |l| out.puts "  - #{printable(l.chomp)}" }
      mutated_block.each_line  { |l| out.puts "  + #{printable(l.chomp)}" }
    end

    # The source text of `file`: the run's copy when it has one, else the file
    # read in its magic-comment encoding, or UTF-8 (#303, #346).
    #
    # @api private
    # @param file [String] source file path.
    # @return [String] source text.
    def source_for(file) = @source_map[file] || Parser.read(file)

    # Source text, a method name or a file path made safe for a terminal (#163):
    # each control character except tab becomes its Ruby escape (ESC prints as
    # `\e`). A valid string in another encoding (EUC-JP, Shift_JIS) is
    # transcoded to UTF-8. Bytes that are not valid in their encoding are
    # read as UTF-8 and each bad byte prints as `\xNN`, so nothing is lost
    # and the regex never raises (#346). JSON and HTML escape on their own,
    # after the same transcoding.
    #
    # @api private
    # @param text [String] source text.
    # @return [String] the text with control characters and invalid bytes escaped.
    def printable(text)
      utf8_text(text).gsub(/[[:cntrl:]&&[^\t]]/) { |c| c.dump[1..-2] }
    end

    # `text` as valid UTF-8. A valid string in another encoding is
    # transcoded. Invalid bytes become `\xNN`.
    #
    # @api private
    # @param text [String]
    # @return [String]
    def utf8_text(text)
      str = text.to_s
      return str if str.encoding == Encoding::UTF_8 && str.valid_encoding?
      # ASCII-8BIT is "valid" for every byte, and encode raises on a byte
      # UTF-8 cannot hold. Those bytes fall through and print as \xNN.
      if str.encoding != Encoding::ASCII_8BIT && str.valid_encoding?
        # A valid byte with no Unicode mapping (0xA5 in ISO-8859-3) prints as
        # \xNN too, so one such byte cannot stop the report.
        return str.encode(Encoding::UTF_8, fallback: ->(c) { escaped_bytes(c) })
      end

      str.dup.force_encoding(Encoding::UTF_8).scrub { |bytes| escaped_bytes(bytes) }
    end

    # Each byte of `bytes` as `\xNN`.
    #
    # @api private
    # @param bytes [String]
    # @return [String]
    def escaped_bytes(bytes)
      bytes.unpack("C*").map { |b| format("\\x%02X", b) }.join
    end

    # A JSON document with every string as UTF-8 (#346). A path whose bytes
    # are not UTF-8 is binary, and `JSON.generate` refuses it. Such bytes
    # print as \xNN, as in the human report.
    #
    # @api private
    # @param value [Object] a document built from Hash, Array, String and scalars.
    # @return [Object] the same shape, its strings passed through {#utf8_text}.
    def json_safe(value)
      case value
      when String then utf8_text(value)
      when Hash then value.to_h { |k, v| [json_safe(k), json_safe(v)] }
      when Array then value.map { |v| json_safe(v) }
      else value
      end
    end

    # Writes the final verdict line.
    #
    # @param out [IO] output stream.
    # @param threshold [Float] score threshold.
    # @return [void]
    def verdict(out, threshold)
      score = @agg.mutation_score
      if score.nil?
        if @agg.broken_nil_score?
          out.puts "FAILED: no covered mutants (#{broken_counts_detail}); " \
                   "threshold #{threshold}% cannot pass with a broken harness"
        end
        return
      end

      # Same rule as exit_code, or the report says PASSED on a run that exits 1 —
      # and with --output that wrong verdict is what gets archived.
      passed = @agg.meets_threshold?(threshold)
      if @agg.broken_share_exceeded?
        out.puts "FAILED: #{no_verdict_ratio}; #{score}% covers only part of the run"
      elsif passed != (score >= threshold)
        # The rounded score points the other way, so give the exact counts.
        out.puts "#{passed ? 'PASSED' : 'FAILED'}: #{@agg.killed_count} of #{@agg.covered_count} killed " \
                 "#{passed ? 'meets' : 'is below'} threshold #{threshold}% (the #{score}% score is rounded)"
      elsif passed
        out.puts "PASSED: #{score}% >= threshold #{threshold}%"
      else
        out.puts "FAILED: #{score}% < threshold #{threshold}%"
      end
    end
  end
end
