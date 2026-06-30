# frozen_string_literal: true

require "json"
require "stringio"
require "cgi"
require_relative "mutation"

module Mutineer
  # Renders an AggregateResult: the summary block, mutation score, and per-file
  # survivor diffs. Stream discipline (R14): the report goes to `out` (stdout),
  # diagnostics/warnings go to `err` (stderr), so `mutineer ... > report.txt`
  # captures only the report.
  #
  # `source_map` is { file_path => raw source string }, used to extract the
  # containing source line for each survivor diff.
  class Reporter
    def initialize(aggregate, source_map)
      @agg = aggregate
      @source_map = source_map
    end

    # Single entry point (R20/R21). Branches on `format` ("human" | "json") and
    # routes the rendered report to `output` (a file, with a stderr confirmation)
    # or to `out`. Diagnostics always go to `err`.
    def report(out: $stdout, err: $stderr, threshold: 0.0, format: "human", output: nil, baseline: nil)
      rendered =
        if format == "json"
          json_report(baseline)
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
      verdict(out, threshold) if threshold && threshold.positive?
    end

    # 0 pass / 1 below threshold. Usage errors (exit 2) are the CLI's job.
    def exit_code(threshold:)
      return 0 if threshold.nil? || threshold <= 0

      score = @agg.mutation_score
      return 0 if score.nil? # no testable mutants — gate skipped (warning already emitted)

      score >= threshold ? 0 : 1
    end

    private

    # Canonical machine-readable schema (KTD7). survivors/no_coverage are sorted
    # by (file, line, operator) so output is byte-stable regardless of --jobs
    # worker finish order (R22).
    # Renders the JSON report.
    #
    # @api private
    # @param baseline [Mutineer::Baseline::Delta, nil] baseline delta.
    # @return [String] JSON text.
    def json_report(baseline = nil)
      killed = @agg.killed_count
      survived = @agg.survived_count
      # C8: null (not 0.0) on an empty denominator, matching the nil-vs-0.0
      # discipline in AggregateResult; and the SAME rounding as the human report
      # (one run must not yield two scores by --format).
      score = @agg.mutation_score

      doc = {
        schema_version: "1.1",
        summary: {
          total: @agg.total, killed: killed, survived: survived,
          no_coverage: @agg.no_coverage_count,
          uncapturable: @agg.uncapturable_count,
          skipped_invalid: @agg.skipped_invalid_count,
          errored: @agg.errored_count, timeout: @agg.timeout_count,
          ignored: @agg.ignored_count,
          score: score
        },
        survivors: @agg.surviving_mutants.map { |r| survivor_json(r) }
                       .sort_by { |h| [h[:file], h[:line], h[:operator]] },
        no_coverage: @agg.results.select(&:no_coverage?).map { |r| no_coverage_json(r) }
                         .sort_by { |h| [h[:file], h[:line]] },
        # #9: same shape as no_coverage; additive key.
        uncapturable: @agg.results.select(&:uncapturable?).map { |r| no_coverage_json(r) }
                          .sort_by { |h| [h[:file], h[:line]] },
        # #10: equivalent mutants the user suppressed — emitted with their stable
        # id so the user can audit what is silenced (and copy ids for survivors
        # they want to add). Excluded from the score; never in `survivors`.
        ignored: @agg.results.select(&:ignored?).map { |r| ignored_json(r) }
                     .sort_by { |h| [h[:file], h[:line], h[:operator]] },
        # #11: per-source breakdown (additive; #13 consumes it). Sorted by file so
        # output is byte-stable. Reuses AggregateResult via by_source.
        per_source: @agg.by_source.map { |file, agg| per_source_json(file, agg) }
                        .sort_by { |h| h[:file] }
      }
      # #13: additive baseline-delta block, present only with --baseline. Existing
      # consumers ignore the extra key; schema_version stays 1.1.
      doc[:baseline] = baseline_json(baseline) if baseline
      "#{JSON.generate(doc)}\n"
    end

    # #23: one self-contained HTML file (inline CSS, no external assets) — the
    # overall score + summary counts, a per-source table, and every surviving
    # mutant with its stable id and diff. All source/diff/identifier text is
    # HTML-escaped (CGI.escapeHTML) so a `<`/`>` in source can never break the
    # markup. Reuses survivor_json/per_source_json so one run yields one set of
    # facts regardless of --format.
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
        </body>
        </html>
      HTML
    end

    # The summary counts block for the HTML header.
    def summary_html
      counts = {
        "total" => @agg.total, "killed" => @agg.killed_count,
        "survived" => @agg.survived_count, "no_coverage" => @agg.no_coverage_count,
        "uncapturable" => @agg.uncapturable_count, "ignored" => @agg.ignored_count,
        "skipped" => @agg.skipped_invalid_count,
        "errored" => @agg.errored_count + @agg.timeout_count
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

    # HTML-escapes any text destined for the document (stdlib CGI).
    def esc(text) = CGI.escapeHTML(text.to_s)

    # #13: the same delta facts the human report prints, for dashboards. new_survivors
    # reuse the ignored_json shape (subject/file/line/operator/token/id) and sort
    # byte-stably so output doesn't depend on --jobs finish order.
    def baseline_json(delta)
      {
        regressed: delta.regressed,
        score_before: delta.score_before,
        score_after: delta.score_after,
        score_dropped: delta.score_drop,
        new_survivors: delta.new_survivors.map { |r| ignored_json(r) }
                            .sort_by { |h| [h[:file], h[:line], h[:operator]] },
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
      minus = original_block.each_line.map { |l| "-#{l.chomp}" }.join("\n")
      plus  = mutated_block.each_line.map { |l| "+#{l.chomp}" }.join("\n")
      {
        subject: result.subject.qualified_name,
        file: file,
        line: start_line,
        operator: m.operator.to_s,
        # #10: the stable, copy-pasteable id (next to the human-readable token) so a
        # user can paste it straight into .mutineer.yml `ignore:`.
        id: result.id,
        token: token,
        diff: "--- a/#{file}\n+++ b/#{file}\n@@ -#{start_line} +#{start_line} @@\n#{minus}\n#{plus}\n"
      }
    end

    # An entry under the JSON `ignored:` key — what the user already suppressed.
    def ignored_json(result)
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
      # Byte math (C1): Prism offsets are byte offsets; byteindex/byterindex/
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

    # Builds no-coverage JSON.
    #
    # @api private
    # @param result [Mutineer::Result] result object.
    # @return [Hash] no-coverage JSON object.
    def no_coverage_json(result)
      m = result.mutation
      file = result.subject.file
      source = @source_map[file] || File.read(file)
      {
        subject: result.subject.qualified_name,
        file: file,
        line: source.byteslice(0, m.start_offset).count("\n") + 1
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
      out.puts format("Skipped:      %-6d  Errored:       %d", @agg.skipped_invalid_count,
                      @agg.errored_count + @agg.timeout_count)
      # #9: a broken harness, not a coverage gap — report it distinctly from No coverage.
      out.puts format("Uncapturable: %-6d  (tests failed to run)", @agg.uncapturable_count)
      # #10: equivalent mutants the user suppressed; excluded from the denominator.
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
                 "#{@agg.skipped_invalid_count} skipped, " \
                 "#{@agg.errored_count + @agg.timeout_count} errored, " \
                 "#{@agg.ignored_count} ignored excluded"
      if score.nil?
        out.puts "Mutation score: N/A  (no covered mutants)"
        err.puts "[mutineer] no covered mutations; mutation score is N/A and the threshold check is skipped."
      else
        out.puts "Mutation score: #{score}%  (killed / (killed + survived); #{excluded})"
      end
    end

    # #11: one line per source after the global summary, so a multi-source run
    # shows which file is weak. Omitted for a single-source run — the global
    # summary already says everything (ponytail: no redundant one-line block).
    # Writes the per-source breakdown.
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
                        file, score.nil? ? "N/A" : "#{score}%",
                        agg.killed_count, agg.survived_count, agg.no_coverage_count)
      end
    end

    # #13: the --baseline delta, appended after the normal report. Names every NEW
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
        out.puts "  + #{r.subject.qualified_name} (#{file}:#{line}) #{r.mutation.operator}"
      end
      out.puts "score dropped #{delta.score_before}% -> #{delta.score_after}%" if delta.score_drop
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
        out.puts file
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

      out.puts "  #{result.subject.qualified_name} (#{File.basename(file)}:#{start_line})"
      out.puts "  Operator: #{m.operator}  (#{token} -> #{m.replacement})"
      original_block.each_line { |l| out.puts "  - #{l.chomp}" }
      mutated_block.each_line  { |l| out.puts "  + #{l.chomp}" }
    end

    # Writes the final verdict line.
    #
    # @param out [IO] output stream.
    # @param threshold [Float] score threshold.
    # @return [void]
    def verdict(out, threshold)
      score = @agg.mutation_score
      return if score.nil?

      if score >= threshold
        out.puts "PASSED: #{score}% >= threshold #{threshold}%"
      else
        out.puts "FAILED: #{score}% < threshold #{threshold}%"
      end
    end
  end
end
