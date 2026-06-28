# frozen_string_literal: true

require "json"
require "stringio"
require_relative "mutation"

module Brutus
  # Renders an AggregateResult: the summary block, mutation score, and per-file
  # survivor diffs. Stream discipline (R14): the report goes to `out` (stdout),
  # diagnostics/warnings go to `err` (stderr), so `brutus ... > report.txt`
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

      out.puts "Brutus — Mutation Results"
      out.puts "========================="
      out.puts
      summary(out)
      out.puts
      score_line(out, err)

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
      denom = killed + survived
      score = denom.zero? ? 0.0 : (killed.to_f / denom * 100).round(2)

      doc = {
        schema_version: "1.0",
        summary: {
          total: @agg.total, killed: killed, survived: survived,
          no_coverage: @agg.no_coverage_count,
          skipped_invalid: @agg.skipped_invalid_count,
          errored: @agg.errored_count, timeout: @agg.timeout_count,
          score: score
        },
        survivors: @agg.surviving_mutants.map { |r| survivor_json(r) }
                       .sort_by { |h| [h[:file], h[:line], h[:operator]] },
        no_coverage: @agg.results.select(&:no_coverage?).map { |r| no_coverage_json(r) }
                         .sort_by { |h| [h[:file], h[:line]] }
      }
      "#{JSON.generate(doc)}\n"
    end

    def survivor_json(result)
      m = result.mutation
      file = result.subject.file
      source = @source_map[file] || File.read(file)
      idx = source[0...m.start_offset].count("\n")
      original = source.lines[idx].chomp
      mutated = m.apply(source).lines[idx].chomp
      {
        subject: result.subject.qualified_name,
        file: file,
        line: idx + 1,
        operator: m.operator.to_s,
        diff: "--- a/#{file}\n+++ b/#{file}\n@@ -#{idx + 1} +#{idx + 1} @@\n-#{original}\n+#{mutated}\n"
      }
    end

    def no_coverage_json(result)
      m = result.mutation
      file = result.subject.file
      source = @source_map[file] || File.read(file)
      {
        subject: result.subject.qualified_name,
        file: file,
        line: source[0...m.start_offset].count("\n") + 1
      }
    end

    def summary(out)
      out.puts "Summary"
      out.puts "-------"
      out.puts format("Total:        %-6d  Killed:        %d", @agg.total, @agg.killed_count)
      out.puts format("Survived:     %-6d  No coverage:   %d", @agg.survived_count, @agg.no_coverage_count)
      out.puts format("Skipped:      %-6d  Errored:       %d", @agg.skipped_invalid_count,
                      @agg.errored_count + @agg.timeout_count)
    end

    def score_line(out, err)
      score = @agg.mutation_score
      excluded = "#{@agg.no_coverage_count} no-coverage, #{@agg.skipped_invalid_count} skipped, " \
                 "#{@agg.errored_count + @agg.timeout_count} errored excluded"
      if score.nil?
        out.puts "Mutation score: N/A  (no covered mutants)"
        err.puts "[brutus] no covered mutations; mutation score is N/A and the threshold check is skipped."
      else
        out.puts "Mutation score: #{score}%  (killed / (killed + survived); #{excluded})"
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
      line_index = source[0...m.start_offset].count("\n") # 0-based
      original = source.lines[line_index].chomp
      mutated  = m.apply(source).lines[line_index].chomp
      token = source[m.start_offset...m.end_offset]

      out.puts "  #{result.subject.qualified_name} (#{File.basename(file)}:#{line_index + 1})"
      out.puts "  Operator: #{m.operator}  (#{token} -> #{m.replacement})"
      out.puts "  - #{original.strip}"
      out.puts "  + #{mutated.strip}"
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
