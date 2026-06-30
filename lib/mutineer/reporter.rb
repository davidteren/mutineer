# frozen_string_literal: true

require "json"
require "stringio"
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
    def report(out: $stdout, err: $stderr, threshold: 0.0, format: "human", output: nil)
      rendered =
        if format == "json"
          json_report
        else
          sio = StringIO.new
          human_report(sio, err, threshold)
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
    def json_report
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
      "#{JSON.generate(doc)}\n"
    end

    def per_source_json(file, agg)
      {
        file: file, total: agg.total,
        killed: agg.killed_count, survived: agg.survived_count,
        no_coverage: agg.no_coverage_count, score: agg.mutation_score
      }
    end

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

    def survivor(out, file, result)
      m = result.mutation
      source = @source_map[file] || File.read(file)
      start_line, original_block, mutated_block, token = diff_for(m, source)

      out.puts "  #{result.subject.qualified_name} (#{File.basename(file)}:#{start_line})"
      out.puts "  Operator: #{m.operator}  (#{token} -> #{m.replacement})"
      original_block.each_line { |l| out.puts "  - #{l.chomp}" }
      mutated_block.each_line  { |l| out.puts "  + #{l.chomp}" }
    end

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
