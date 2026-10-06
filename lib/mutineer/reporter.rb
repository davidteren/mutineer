# frozen_string_literal: true

require "json"
require "stringio"
require "cgi"
require_relative "mutation"

module Mutineer
  # Renders an AggregateResult: the summary block, mutation score, and per-file
  # survivor diffs. Stream discipline: the report goes to `out` (stdout),
  # diagnostics/warnings go to `err` (stderr), so `mutineer ... > report.txt`
  # captures only the report.
  #
  # `source_map` is { file_path => raw source string }, used to extract the
  # containing source line for each survivor diff.
  class Reporter
    # Share of attempted mutants that may produce no verdict before `--threshold`
    # stops trusting the score. A handful of flaky mutants in a large run is noise;
    # a mostly-broken run is not a score. Deliberately not a flag: no one has needed
    # a different number yet.
    BROKEN_SHARE_LIMIT = 0.10

    # A share alone gives a small run no tolerance at all: on a `--since` PR that
    # yields 8 mutants, one timeout is 12.5%. README recommends exactly that
    # workflow, so one bad mutant never fails the gate on its own, at any size.
    BROKEN_FLOOR = 1

    # The JSON report's `schema_version` (see docs/json-schema.md).
    SCHEMA_VERSION = "1.7"

    # The warning both matrix renderers give under the redundant tests.
    MATRIX_REDUNDANT_NOTE = "Delete redundant tests one at a time: two of them can be the only killers of one mutant."

    # How many blind or redundant tests the human report lists before it points
    # to `--format json` for the rest.
    MATRIX_LIST_LIMIT = 20

    # @param aggregate [Mutineer::AggregateResult] the run's results.
    # @param source_map [Hash{String => String}] source file path => source text.
    # @param matrix [Mutineer::KillMatrix, nil] the kill matrix of a `--matrix`
    #   run; nil leaves every format exactly as it is without the flag.
    def initialize(aggregate, source_map, matrix: nil)
      @agg = aggregate
      @source_map = source_map
      @matrix = matrix
    end

    # Single entry point. Branches on `format` ("human" | "json" | "html") and
    # routes the rendered report to `output` (a file, with a stderr confirmation)
    # or to `out`. Diagnostics always go to `err`. `scoped` marks a diff-scoped
    # (`--since`) run; the JSON report records it so a consumer (or a later
    # `--baseline` load) knows the score covers only the changed-line mutants.
    # `legacy_id_matches` (`{ignore:, baseline:}`) counts stored ids still in the
    # old format (#126); only the JSON report records it (`summary.legacy_id_matches`).
    def report(out: $stdout, err: $stderr, threshold: 0.0, format: "human", output: nil,
               baseline: nil, scoped: false, legacy_id_matches: { ignore: 0, baseline: 0 })
      rendered =
        if format == "json"
          json_report(baseline, scoped: scoped, legacy_id_matches: legacy_id_matches)
        elsif format == "html"
          html_report
        else
          sio = StringIO.new
          human_report(sio, err, threshold)
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

      # Both ways a run can fail the gate on completeness, said here rather than in
      # the human renderer: --format json is the documented CI path, and a run that
      # exits 1 must say why on every format, not only the one a person reads.
      return unless threshold&.positive?

      if @agg.mutation_score.nil? && broken_nil_score?
        err.puts "[mutineer] nothing could be scored (#{broken_counts_detail}), so the " \
                 "--threshold gate fails. See no_verdict[] in --format json for the cause of each."
      elsif broken_share_exceeded?
        err.puts "[mutineer] #{no_verdict_ratio}: #{broken_counts_detail}. The score covers " \
                 "only part of the run, so the --threshold gate fails. See no_verdict[] in " \
                 "--format json for the cause of each."
      end
    end

    # Renders the human report.
    #
    # @param out [IO] output stream.
    # @param err [IO] error stream.
    # @param threshold [Float] score threshold.
    # @return [void]
    def human_report(out, err, threshold)
      if @agg.total.zero?
        err.puts "No mutations generated — verify target files contain in-scope " \
                 "operators and are reached by the suite."
        return
      end

      out.puts "Mutineer — Mutation Results"
      out.puts "========================="
      out.puts
      summary(out)
      out.puts
      score_line(out, err)
      per_source(out)

      survivors(out)
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

      score = @agg.mutation_score
      if score.nil?
        broken = @agg.errored_count + @agg.timeout_count + @agg.uncapturable_count
        return 1 if @agg.total.positive? && broken.positive?

        return 0 # pure no_coverage / ignored / empty — gate skipped
      end

      # A score computed over a small slice of what was attempted is not this
      # suite's score. Without this, 90 errored mutants and 10 that ran (9 killed)
      # reports 90% and exits 0, so CI cannot tell a complete run from a broken one.
      return 1 if broken_share_exceeded?

      score >= threshold ? 0 : 1
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
    # @return [String] JSON text.
    def json_report(baseline = nil, scoped: false, legacy_id_matches: { ignore: 0, baseline: 0 })
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
          # The gate is computed from these two, so a consumer never re-derives them.
          attempted: attempted_count, no_verdict: no_verdict_count,
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
          legacy_id_matches: legacy_id_matches
        },
        survivors: @agg.surviving_mutants.map { |r| survivor_json(r) }
                       .sort_by { |h| [h[:file], h[:line], h[:operator]] },
        # id extends the key to a total order: several mutants share a line.
        no_coverage: @agg.results.select(&:no_coverage?).map { |r| mutant_json(r) }
                         .sort_by { |h| [h[:file], h[:line], h[:operator], h[:id].to_s] },
        # Same shape as no_coverage; additive key.
        uncapturable: @agg.results.select(&:uncapturable?).map { |r| mutant_json(r) }
                          .sort_by { |h| [h[:file], h[:line], h[:operator], h[:id].to_s] },
        # Additive (1.7): owner-unknown mutants redefine did not run. Not in no_verdict.
        unplaceable: @agg.results.select(&:unplaceable?).map { |r| mutant_json(r) }
                         .sort_by { |h| [h[:file], h[:line], h[:operator], h[:id].to_s] },
        # Additive (1.7, #187): mutants on a line that ran at load. Not in no_verdict.
        ran_at_load: @agg.results.select(&:ran_at_load?).map { |r| mutant_json(r) }
                         .sort_by { |h| [h[:file], h[:line], h[:operator], h[:id].to_s] },
        # Every mutant that was attempted and produced no verdict, whatever the
        # reason — the set the --threshold completeness gate counts. Named for the
        # condition rather than one status, because summary.errored means :error
        # alone and a key that reconciled with neither would be worse. `details`
        # carries the cause where there is one. Uncapturable mutants also appear in
        # uncapturable[], which stays for consumers that already read it.
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
        ignored: @agg.results.select(&:ignored?).map { |r| mutant_json(r) }
                     .sort_by { |h| [h[:file], h[:line], h[:operator], h[:id].to_s] },
        # Per-source breakdown (additive; baseline consumes it). Sorted by file so
        # output is byte-stable. Reuses AggregateResult via by_source.
        per_source: @agg.by_source.map { |file, agg| per_source_json(file, agg) }
                        .sort_by { |h| h[:file] }
      }
      # Additive (1.5): the kill matrix, present only with --matrix.
      doc[:matrix] = matrix_json if @matrix
      # Additive baseline-delta block, present only with --baseline. Existing
      # consumers ignore the extra key; it does not move schema_version on its own.
      doc[:baseline] = baseline_json(baseline) if baseline
      "#{JSON.generate(doc)}\n"
    end

    # One self-contained HTML file (inline CSS, no external assets): the overall
    # score + summary counts, a per-source table, and every surviving mutant with
    # its stable id and diff. All source/diff/identifier text is HTML-escaped
    # (CGI.escapeHTML) so a `<`/`>` in source can never break the markup. Reuses
    # survivor_json/per_source_json so one run yields one set of facts regardless
    # of --format.
    def html_report
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
        #{summary_html}
        #{per_source_html(per_source)}
        #{survivors_html(survivors)}
        #{matrix_html}
        </body>
        </html>
      HTML
    end

    # The summary counts block for the HTML header.
    def summary_html
      counts = {
        "total" => @agg.total, "killed" => @agg.killed_count,
        "survived" => @agg.survived_count, "no_coverage" => @agg.no_coverage_count,
        "uncapturable" => @agg.uncapturable_count, "unplaceable" => @agg.unplaceable_count,
        "ran_at_load" => @agg.ran_at_load_count, "ignored" => @agg.ignored_count,
        "skipped" => @agg.skipped_invalid_count,
        "errored" => @agg.errored_count, "timeout" => @agg.timeout_count
      }
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
          <pre class="diff">#{diff_lines}</pre>
          </div>
        CARD
      end.join("\n")
      "<h2>Surviving Mutants</h2>\n#{cards}"
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

      source = @source_map[file] || File.read(file)
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
    def esc(text) = CGI.escapeHTML(text.to_s)

    # The same delta facts the human report prints, for dashboards. new_survivors
    # reuse the mutant_json shape (subject/file/line/operator/token/id) and sort
    # byte-stably so output does not depend on --jobs finish order.
    def baseline_json(delta)
      {
        regressed: delta.regressed,
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
        end.sort_by { |h| [h[:file].to_s, h[:line].to_i, h[:operator].to_s] }
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

    # Builds survivor JSON.
    #
    # @api private
    # @param result [Mutineer::Result] survivor result.
    # @return [Hash] survivor JSON object.
    def survivor_json(result)
      m = result.mutation
      file = result.subject.file
      source = @source_map[file] || File.read(file)
      start_line, original_block, mutated_block, token = diff_for(m, source)
      # A block at the end of the file has no newline after it; elsewhere the
      # file's next byte is one. Each side's own text decides its marker.
      at_eof = source.byteindex("\n", m.end_offset).nil?
      old_lines = side_lines(original_block, at_eof)
      new_lines = side_lines(mutated_block, at_eof)
      {
        subject: result.subject.qualified_name,
        file: file,
        line: start_line,
        operator: m.operator.to_s,
        # The stable, copy-pasteable id (next to the human-readable token) so a
        # user can paste it straight into .mutineer.yml `ignore:`.
        id: result.id,
        token: token,
        diff: "--- a/#{file}\n+++ b/#{file}\n" \
              "@@ -#{hunk_range(start_line, old_lines)} +#{hunk_range(start_line, new_lines)} @@\n" \
              "#{diff_body("-", old_lines)}#{diff_body("+", new_lines)}"
      }
    end

    # One side of the diff as the file holds it: the {#diff_for} block plus the
    # newline that follows it, unless the block ends the file. Each line keeps
    # its own ending, so a CRLF line keeps its "\r" and a last line with no
    # newline is told apart from one with a newline.
    #
    # @api private
    # @param block [String] the block's text.
    # @param at_eof [Boolean] no newline follows the block in the file.
    # @return [Array<String>] its lines, with their endings.
    def side_lines(block, at_eof)
      (at_eof ? block : "#{block}\n").lines
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

    # The fields that name one mutant, for the lists that point at mutants:
    # `no_coverage`, `uncapturable`, `unplaceable`, `ran_at_load`, `ignored` and
    # `baseline.new_survivors`.
    def mutant_json(result)
      m = result.mutation
      file = result.subject.file
      source = @source_map[file] || File.read(file)
      start_line, _orig, _mut, token = diff_for(m, source)
      {
        subject: result.subject.qualified_name,
        file: file,
        line: start_line,
        operator: m.operator.to_s,
        token: token,
        id: result.id
      }
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
      mutated_block  = "#{before}#{m.replacement}#{after}"
      start_line  = source.byteslice(0, m.start_offset).count("\n") + 1
      token       = source.byteslice(m.start_offset...m.end_offset).gsub(/\s+/, " ").strip
      token       = "#{token[0, 47]}..." if token.length > 50
      [start_line, original_block, mutated_block, token]
    end

    # An entry under the JSON `no_verdict:` key: an attempted mutant with no verdict.
    # A pre-fork failure has no subject or mutation attached, so those degrade to
    # nulls rather than dropping the entry — the count must still reconcile with
    # `summary.no_verdict`.
    #
    # @api private
    # @param result [Mutineer::Result] an errored or timed-out result.
    # @return [Hash] no-verdict JSON object.
    def no_verdict_json(result)
      {
        subject: result.subject&.qualified_name,
        file: result.subject&.file,
        line: result_line(result),
        id: result.id,
        status: result.status.to_s,
        details: result.details
      }
    end

    # Writes the summary block.
    #
    # @param out [IO] output stream.
    # @return [void]
    def summary(out)
      out.puts "Summary"
      out.puts "-------"
      out.puts format("Total:        %-6d  Killed:        %d", @agg.total, @agg.killed_count)
      out.puts format("Survived:     %-6d  No coverage:   %d", @agg.survived_count, @agg.no_coverage_count)
      out.puts format("Skipped:      %-6d  Errored:       %d", @agg.skipped_invalid_count, @agg.errored_count)
      out.puts format("Timeout:      %-6d  (over the per-mutant time limit)", @agg.timeout_count)
      # A broken harness, not a coverage gap: report it distinctly from No coverage.
      out.puts format("Uncapturable: %-6d  (tests failed to run)", @agg.uncapturable_count)
      # Not broken: redefine has no named class to load these onto; reload runs them.
      out.puts format("Unplaceable:  %-6d  (class cannot be named statically; --strategy reload runs these)",
                      @agg.unplaceable_count)
      # Not a verdict: the line ran before the mutant was applied (#187).
      out.puts format("Ran at load:  %-6d  (ran while the app or class loaded; mutineer cannot re-run that; " \
                      "verify with --test-command)", @agg.ran_at_load_count)
      # Equivalent mutants the user suppressed; excluded from the denominator.
      out.puts format("Ignored:      %-6d  (equivalent, suppressed)", @agg.ignored_count)
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
                 "#{@agg.ignored_count} ignored excluded"
      if score.nil?
        out.puts "Mutation score: N/A  (no covered mutants)"
        # Only the benign case here: the gate-failure explanation is emitted once
        # from {report}, for every format, so it cannot be said twice or only to
        # the reader of the human report.
        unless broken_nil_score?
          err.puts "[mutineer] no covered mutations; mutation score is N/A and the threshold check is skipped."
        end
      else
        out.puts "Mutation score: #{score}%  (killed / (killed + survived); #{excluded})"
      end
    end

    # True when nil score is due to errors/timeouts/uncapturable (gate must fail).
    #
    # @api private
    # @return [Boolean]
    def broken_nil_score?
      @agg.total.positive? &&
        (@agg.errored_count + @agg.timeout_count + @agg.uncapturable_count).positive?
    end

    # Mutants that were attempted but produced no verdict, over everything
    # attempted. Above the limit the score describes too small a slice of the run
    # to gate on. A few flaky mutants in a large run stay under it.
    #
    # @api private
    # @return [Boolean] true when too much of the run failed to produce a verdict.
    def broken_share_exceeded?
      attempted = attempted_count
      attempted.positive? && no_verdict_count > BROKEN_FLOOR &&
        no_verdict_count > attempted * BROKEN_SHARE_LIMIT
    end

    # Mutants that were attempted and produced no verdict, whatever the reason.
    #
    # @api private
    # @return [Integer] errored + timed out + uncapturable.
    def no_verdict_count
      @agg.errored_count + @agg.timeout_count + @agg.uncapturable_count
    end

    # Mutants that were actually run. Deliberately not `total`: no_coverage,
    # skipped-invalid and ignored mutants were never attempted, so counting them
    # would dilute the share and let a broken run slip under the limit.
    #
    # skipped-invalid is excluded from both sides: it means a mutant did not
    # re-parse and was correctly never run, which is a validity outcome rather
    # than a broken harness. Cost: an overwhelmingly-skipped run still scores on
    # what little ran; that is our operator misbehaving and wants its own signal.
    #
    # @api private
    # @return [Integer] killed + survived + no-verdict.
    def attempted_count
      @agg.killed_count + @agg.survived_count + no_verdict_count
    end

    # The sentence both the verdict line and the stderr note are built from, so a
    # user cannot read one number in the report and a different one beside it.
    #
    # @api private
    # @return [String] e.g. "90 of 100 attempted mutants produced no verdict (90.0%, limit 10%)".
    def no_verdict_ratio
      pct = (no_verdict_count * 100.0 / attempted_count).round(1)
      "#{no_verdict_count} of #{attempted_count} attempted mutants produced no verdict " \
        "(#{pct}%, limit #{(BROKEN_SHARE_LIMIT * 100).round}%)"
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
    # survivor (subject (file:line) operator) and the score delta when it dropped,
    # then a one-line REGRESSION/OK verdict so CI logs show which gate fired.
    def baseline_section(out, delta)
      out.puts
      out.puts "Baseline comparison"
      out.puts "-------------------"
      out.puts "killed #{@agg.killed_count}, #{delta.new_survivors.size} new survivors vs baseline"
      delta.new_survivors
           .sort_by { |r| [r.subject.file, r.mutation.start_offset] }
           .each do |r|
        file = r.subject.file
        source = @source_map[file] || File.read(file)
        line, = diff_for(r.mutation, source)
        out.puts "  + #{printable(r.subject.qualified_name)} (#{printable(file)}:#{line}) #{r.mutation.operator}"
      end
      out.puts "score dropped #{delta.score_before}% -> #{delta.score_after}%" if delta.score_drop
      # An OK verdict must not imply a check that never ran: say when the score
      # comparison was skipped (a diff-scoped side or a nil score).
      out.puts "score-drop check skipped (scores not comparable)" unless delta.score_comparable
      out.puts(delta.regressed ? "REGRESSION vs baseline" : "OK: no regression vs baseline")
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
        group.sort_by { |r| r.mutation.start_offset }.each { |r| survivor(out, file, r) }
      end
    end

    # Writes one survivor entry.
    #
    # @param out [IO] output stream.
    # @param file [String] source file path.
    # @param result [Mutineer::Result] survivor result.
    # @return [void]
    def survivor(out, file, result)
      m = result.mutation
      source = @source_map[file] || File.read(file)
      start_line, original_block, mutated_block, token = diff_for(m, source)

      out.puts "  #{printable(result.subject.qualified_name)} (#{printable(File.basename(file))}:#{start_line})"
      out.puts "  Operator: #{m.operator}  (#{printable(token)} -> #{printable(m.replacement)})"
      original_block.each_line { |l| out.puts "  - #{printable(l.chomp)}" }
      mutated_block.each_line  { |l| out.puts "  + #{printable(l.chomp)}" }
    end

    # Source text, a method name or a file path made safe for a terminal (#163):
    # each control character except tab becomes its Ruby escape (ESC prints as
    # `\e`). The text is read as UTF-8 whatever the locale, and each byte that is
    # not valid UTF-8 (a Latin-1 source, say) prints as `\xNN`, so nothing is
    # lost and the regex never raises. JSON and HTML escape on their own.
    #
    # @api private
    # @param text [String] source text.
    # @return [String] the text with control characters and invalid bytes escaped.
    def printable(text)
      text.dup.force_encoding(Encoding::UTF_8)
          .scrub { |bytes| bytes.unpack("C*").map { |b| format("\\x%02X", b) }.join }
          .gsub(/[[:cntrl:]&&[^\t]]/) { |c| c.dump[1..-2] }
    end

    # Writes the final verdict line.
    #
    # @param out [IO] output stream.
    # @param threshold [Float] score threshold.
    # @return [void]
    def verdict(out, threshold)
      score = @agg.mutation_score
      if score.nil?
        if broken_nil_score?
          out.puts "FAILED: no covered mutants (#{broken_counts_detail}); " \
                   "threshold #{threshold}% cannot pass with a broken harness"
        end
        return
      end

      # Same rule as exit_code, or the report says PASSED on a run that exits 1 —
      # and with --output that wrong verdict is what gets archived.
      if broken_share_exceeded?
        out.puts "FAILED: #{no_verdict_ratio}; #{score}% covers only part of the run"
      elsif score >= threshold
        out.puts "PASSED: #{score}% >= threshold #{threshold}%"
      else
        out.puts "FAILED: #{score}% < threshold #{threshold}%"
      end
    end
  end
end
