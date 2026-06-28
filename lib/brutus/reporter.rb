# frozen_string_literal: true

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

    def report(out: $stdout, err: $stderr, threshold: 0.0)
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
