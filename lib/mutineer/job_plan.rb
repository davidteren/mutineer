# frozen_string_literal: true

require "digest"
require "set"
require_relative "parser"
require_relative "project"
require_relative "result"
require_relative "statement_lines"
require_relative "changed_lines"
require_relative "mutator_registry"
require_relative "mutant_id"
require_relative "project_path"
require_relative "external_backend"

module Mutineer
  # The job vocabulary every backend shares: which mutants run, which are
  # ignored, which lines `--since` keeps, which tests cover a mutant, and the
  # source and test directories a run touches. {Runner}, {DaemonBackend} and
  # {CLI} each require this file, so job selection cannot drift between them
  # (score parity), and the require graph has no cycles (#75). Never require
  # runner.rb, daemon_backend.rb or cli.rb from here: each requires this file.
  module JobPlan
    # Collect every (subject, mutation, id) up front so a backend can run them.
    # A mutant the user marked known-equivalent (inline disable-line comment or
    # .mutineer.yml ignore id) is classified :ignored here and NEVER run. It is
    # removed from the killed+survived denominator so a strong file reaches 100%.
    # The id is computed per subject (occurrence needs the full list), keyed on
    # the file path relative to config.project_root, and carried on every job so
    # the parent can reattach it after the run. Shared by the in-process,
    # external, and daemon backends so job selection can never drift.
    #
    # Each mutant also gets its old-format id ({MutantId.legacy_for}). A bare
    # old id does not match `ignore:` or a baseline. A mapping's id still
    # matches, including an old id, unless that string is already a current id
    # in this run. The extras hash returns `id_map` (every new id => its
    # old-format id) so `mutineer migrate` can rewrite old ignore entries.
    # Prints nothing.
    #
    # Subjects sharing a qualified name in one file (two owner-less `def index`
    # in two DSL blocks) get a per-file ordinal in discovery order, so their ids
    # differ; the first one's ordinal is 0 and leaves its id unchanged.
    #
    # @param config [Mutineer::Config] run configuration.
    # @param operator_classes [Array<Class>] resolved operators.
    # @return [Array(Array, Array<Result>, Hash<String,String>, Hash{Symbol => Hash})]
    #   jobs, ignored, source_map, and extras (`:id_map`).
    def self.collect_jobs(config, operator_classes)
      source_map = {}
      disabled_map = {}
      id_paths = {}
      # [file, qualified_name] => { declaration offset => ordinal }: keyed by the
      # declaration, so the same file discovered twice (two path spellings) reuses
      # its ordinal instead of minting a second id for the same mutant.
      name_decls = Hash.new { |h, k| h[k] = {} }
      ignore_set = config.ignore.to_set
      ignore_reasons = config.ignore_reasons || {}
      mapped_ids = Array(config.ignore_mapped_ids).to_set
      records = []
      Project.discover(config.sources, only: config.only).each do |subject|
        source = (source_map[subject.file] ||= File.read(subject.file))
        disabled = (disabled_map[subject.file] ||= suppress_map(source, subject.file))
        mutations = operator_classes.flat_map { |klass| klass.new.mutations_for(subject, source) }
        id_path = (id_paths[subject.file] ||= ProjectPath.relative(subject.file, config.project_root))
        decls = name_decls[[id_path, subject.qualified_name]]
        ordinal = (decls[subject.def_node.location.start_offset] ||= decls.size)
        ids = MutantId.for_subject(subject, source, mutations, path: id_path, subject_ordinal: ordinal)
        legacy_ids = MutantId.legacy_for_subject(subject, source, mutations)
        lines = mutations.map { |m| source.byteslice(0, m.start_offset).count("\n") + 1 }
        keys = result_keys(mutations, source, lines)
        mutations.each_with_index do |mutation, i|
          records << [subject, mutation, ids[i], legacy_ids[i], lines[i], keys[i], disabled]
        end
      end

      # A mapping id that is already some mutant's current id must not also
      # suppress another mutant that still hashes to that string as its old id.
      current_ids = records.map { |row| row[2] }.to_set
      jobs = []
      ignored_results = []
      id_map = {}
      records.group_by(&:first).each_value do |group|
        # A repeat of an earlier edit on the same line is dropped (#159),
        # separately among the run and the ignored mutants, so an ignored copy
        # never hides a copy that should run. A dropped copy records nothing.
        seen = { run: Set.new, ignored: Set.new }
        group.each do |subject, mutation, id, legacy, line, key, disabled|
          legacy_hit = mapped_ids.include?(legacy) && !current_ids.include?(legacy) && ignore_set.include?(legacy)
          match_ids = legacy_hit ? [id, legacy] : id
          ignored = suppressed?(mutation.operator, line, match_ids, disabled, ignore_set)
          next unless seen[ignored ? :ignored : :run].add?(key)

          id_map[id] = legacy
          if ignored
            reason = suppression_reason(mutation.operator, line, match_ids, disabled, ignore_reasons)
            ignored_results << Result.ignored.with(subject: subject, mutation: mutation, id: id, reason: reason)
          else
            jobs << [subject, mutation, id]
          end
        end
      end
      [jobs, ignored_results, source_map, { id_map: id_map }]
    end

    # One key per mutation; two mutations share a key exactly when they are
    # the same operator on the same line and give the same mutated source (one
    # edit, #159). The caller drops a repeat after ids are assigned. Only a
    # group of same-operator, same-line mutations can repeat, so only those
    # build a key from their text: the span from the group's earliest start to
    # its latest end, digested. Every other mutation gets a key of its own.
    #
    # @param mutations [Array<Mutineer::Mutation>] one subject's mutations.
    # @param source [String] the full, unmutated source.
    # @param lines [Array<Integer>] each mutation's line.
    # @return [Array<Object>] one key per mutation, in order.
    def self.result_keys(mutations, source, lines)
      keys = Array.new(mutations.size) { |i| i }
      mutations.each_index.group_by { |i| [mutations[i].operator, lines[i]] }.each_value do |group|
        next if group.size < 2

        from = group.map { |i| mutations[i].start_offset }.min
        to = group.map { |i| mutations[i].end_offset }.max
        group.each do |i|
          m = mutations[i]
          span = "#{source.byteslice(from...m.start_offset)}#{m.replacement}#{source.byteslice(m.end_offset...to)}"
          keys[i] = [m.operator, lines[i], Digest::SHA256.digest(span)]
        end
      end
      keys
    end

    # Aborts the run when coverage capture saw a red unmutated suite. Scoring
    # those results would treat existing assertion failures as killed mutants.
    #
    # @param coverage_map [Mutineer::CoverageMap] the built or loaded map.
    # @return [void]
    # @raise [Mutineer::SmokeCheckError] when any captured test failed clean,
    #   or when no test recorded coverage and a capture failed.
    def self.abort_if_unclean!(coverage_map)
      if coverage_map.map.empty? && coverage_map.failed_test_files.any?
        raise SmokeCheckError, "no test recorded coverage, and capture failed for #{coverage_map.failed_test_files.join(', ')}"
      end

      files = coverage_map.failed_clean_tests
      return if files.empty?

      raise SmokeCheckError,
            "the unmutated suite is not green (#{files.join(', ')}) — " \
            "#{ExternalBackend.generic_env_hint}."
    end

    # Coverage-based test selection, shared by the in-process ({Runner.run}) and daemon
    # paths so both narrow identically (score parity). Returns
    # `[:run, abs_test_paths]` when some test covers the mutant's line, in the
    # order of {CoverageMap#order_tests} (paired files, then cheapest), or
    # `[:verdict, Result]` (no_coverage / uncapturable) when none do. A line
    # Ruby does not count (a later line of a multi-line statement) uses the
    # tests that ran the statement that holds it ({StatementLines}), unless the
    # mutant sits in code of that statement that runs only sometimes.
    #
    # An empty selection is `:ran_at_load` when the mutant's line ran while the
    # app booted or its class loaded ({ran_at_load?}): no test ran it, but the
    # load did, so it is not a coverage gap.
    #
    # An empty selection is `:uncapturable` (not `:no_coverage`) when the
    # mutant's enclosing method body got coverage from no *successful* capture but
    # a sibling test failed to capture: the coverage was lost, not absent. Both are
    # excluded from the score denominator, so this distinction is reporting-only
    # and never changes the daemon-vs-in-process score.
    #
    # @param source_file [String] the mutated source file path.
    # @param mutation [Mutineer::Mutation] the mutation (for its line offset).
    # @param subject [Mutineer::Subject, nil] the subject (for its method body range).
    # @param source [String] the original source text.
    # @param coverage_map [Mutineer::CoverageMap] the built/loaded coverage map.
    # @return [Array(Symbol, Object)] `[:run, Array<String>]` or `[:verdict, Result]`.
    def self.coverage_selection(source_file, mutation, subject, source, coverage_map)
      line   = source.byteslice(0, mutation.start_offset).count("\n") + 1
      chosen = coverage_map.tests_for(source_file, line)
      if chosen.empty? && subject
        # A multi-line statement has a count on one of its lines only.
        lines = StatementLines.for(subject.def_node, source, mutation.start_offset)
        chosen = lines.flat_map { |l| coverage_map.tests_for(source_file, l) }.uniq
      end
      if chosen.empty?
        # Method BODY range, not the whole def: the def/end lines are "covered" at
        # class-load even when the body never runs (body_loc is the statements' span).
        loc   = subject&.body_loc
        range = loc ? (loc.start_line..loc.end_line) : (line..line)
        return [:verdict, Result.uncapturable] if coverage_map.method_uncapturable?(source_file, range)
        return [:verdict, Result.ran_at_load] if ran_at_load?(source_file, mutation, subject, source, coverage_map)

        return [:verdict, Result.no_coverage]
      end

      [:run, coverage_map.order_tests(source_file, chosen).map { |t| File.expand_path(t, coverage_map.project_root) }]
    end

    # True when the mutant's line ran while the app booted or its class loaded,
    # so a test can check a value the original code computed before the mutant
    # was applied. Shared by {coverage_selection}, {Runner.run} and the daemon backend.
    #
    # Only the lines of the statement that holds the mutant count
    # ({StatementLines}), and only inside the method body. So code that runs
    # only sometimes (`x if c`, a ternary branch) never counts: its line can
    # count at load without it. The `def` line never counts: Ruby counts it
    # when the method is defined.
    #
    # A one-line or endless def keeps its body on the `def` line, so it uses
    # the method's own call count at load instead (#209), for code that runs
    # each time the method does ({StatementLines.runs_with_method?}).
    #
    # @param source_file [String] the mutated source file path.
    # @param mutation [Mutineer::Mutation] the mutation.
    # @param subject [Mutineer::Subject, nil] the subject (for its method body range).
    # @param source [String] the original source text.
    # @param coverage_map [Mutineer::CoverageMap, nil] the coverage map.
    # @return [Boolean]
    def self.ran_at_load?(source_file, mutation, subject, source, coverage_map)
      loc = subject&.body_loc
      return false unless loc && coverage_map

      def_loc = subject.def_node.location
      def_line = def_loc.start_line
      if loc.end_line == def_line
        return coverage_map.method_ran_at_load?(source_file, def_line, def_loc.start_column) &&
               StatementLines.runs_with_method?(subject.def_node, mutation.start_offset)
      end

      body = (loc.start_line..loc.end_line)
      lines = StatementLines.for(subject.def_node, source, mutation.start_offset)
      lines.any? { |l| l != def_line && body.cover?(l) && coverage_map.ran_at_load?(source_file, l) }
    end

    # A survivor whose line ran at load becomes `ran_at_load` ({ran_at_load?});
    # any other result comes back unchanged. A `--matrix` row is kept.
    #
    # @param result [Mutineer::Result] the mutant's verdict.
    # @param source_file [String] the mutated source file path.
    # @param mutation [Mutineer::Mutation] the mutation.
    # @param subject [Mutineer::Subject, nil] the subject.
    # @param source [String] the original source text.
    # @param coverage_map [Mutineer::CoverageMap, nil] the coverage map.
    # @return [Mutineer::Result]
    def self.load_verdict(result, source_file, mutation, subject, source, coverage_map)
      return result unless result.survived? && ran_at_load?(source_file, mutation, subject, source, coverage_map)

      result.with(status: :ran_at_load)
    end

    # Map each line number to `{ ops:, reason: }`, using inline
    # `# mutineer:disable-line [ops]` markers (RuboCop semantics: the marker
    # sits on the same physical line as the code it silences). `ops` is `:all`
    # or a set of operator symbols. `reason` is the text after `--`, or nil.
    # A bare marker disables every operator on that line; `disable-line a, b`
    # only the listed operators. Block-form disable/enable ranges are
    # intentionally not supported. Only a real `#` comment counts: Prism lists
    # the comments, so the marker text inside a string, heredoc or regex
    # silences nothing (#158).
    #
    # @param source [String] the source text.
    # @param file [String] the file name, for warnings.
    # @return [Hash{Integer => Hash}] line => `{ ops:, reason: }`.
    def self.suppress_map(source, file)
      map = {}
      Parser.comments(source).grep(Prism::InlineComment).each do |comment|
        line = comment.location.start_line
        next unless (m = comment.slice.match(/#\s*mutineer:disable-line(?:\s+([\w,\s]+))?/))

        ops = m[1]&.split(",")&.map(&:strip)&.reject(&:empty?)
        # Only spaces or commas after the marker (e.g. `disable-line  -- why`)
        # is a bare marker, not an empty list that silences nothing.
        ops = nil if ops&.empty?
        unknown = ops.to_a.reject { |o| MutatorRegistry::ALL.key?(o) }
        unknown.each do |o|
          warn "mutineer: unknown operator #{o.inspect} in #{file}:#{line}#{Mutineer.did_you_mean(o, MutatorRegistry::ALL.keys)} " \
               "(known: #{MutatorRegistry::ALL.keys.join(', ')}); write a reason after --"
        end
        reason = comment.slice[/\s--\s*(.*)\z/, 1]&.strip
        reason = nil if reason.nil? || reason.empty?
        map[line] = { ops: ops ? ops.map(&:to_sym).to_set : :all, reason: reason }
      end
      map
    end

    # The operator set for one suppress-map entry. A Hash is the current shape
    # (`ops` plus `reason`). `:all` and a Set remain valid for callers that
    # build the map by hand.
    #
    # @param entry [Hash, Symbol, Set, nil] one line's suppress-map value.
    # @return [Symbol, Set, nil] `:all`, the operator set, or nil.
    def self.line_ops(entry)
      entry.is_a?(Hash) ? entry[:ops] : entry
    end

    # The reason text on one suppress-map entry, when the entry stores one.
    #
    # @param entry [Hash, Object] one line's suppress-map value.
    # @return [String, nil]
    def self.line_reason(entry)
      entry.is_a?(Hash) ? entry[:reason] : nil
    end

    # True when this mutant is suppressed: its line bears a disable-line marker
    # (bare, or scoped to its operator), OR one of `ids` is in the config ignore
    # list. The caller passes the current id. It also passes a mapping's old id
    # when that mapping still applies. A bare old id is not passed, so it does
    # not match. Checked at job-build time so a suppressed mutant is never forked.
    #
    # @param ids [Array<String>, String] the mutant's current id, or several ids.
    def self.suppressed?(operator, line, ids, disabled, ignore_set)
      return true if Array(ids).any? { |id| ignore_set.include?(id) }

      case line_ops(disabled[line])
      when :all then true
      when Set  then line_ops(disabled[line]).include?(operator)
      else false
      end
    end

    # Why an ignored mutant was suppressed. An inline reason wins. Otherwise
    # the reason is the first matching ignore id that has one. Blank text is nil.
    #
    # @param operator [Symbol] the mutant's operator.
    # @param line [Integer] the mutant's line.
    # @param ids [Array<String>, String] the current id, or several ids.
    # @param disabled [Hash] the file's suppress map.
    # @param ignore_reasons [Hash{String => String}] id => reason.
    # @return [String, nil]
    def self.suppression_reason(operator, line, ids, disabled, ignore_reasons)
      entry = disabled[line]
      ops = line_ops(entry)
      line_hit = ops == :all || (ops.is_a?(Set) && ops.include?(operator))
      inline = line_hit ? line_reason(entry) : nil
      return inline if inline.is_a?(String) && !inline.strip.empty?

      Array(ids).each do |candidate|
        text = ignore_reasons[candidate]
        return text if text.is_a?(String) && !text.strip.empty?
      end
      nil
    end

    # Narrows the jobs and the suppressed (ignored) results to --since when it
    # is set, as the dry run does, so a scoped report lists only mutants on
    # changed lines. Also returns how many mutants there were before narrowing
    # (nil without --since), so the CLI can tell "the changes held nothing to
    # test" from "nothing was mutable at all".
    #
    # @param jobs [Array] (subject, mutation, id) entries to run.
    # @param ignored_results [Array<Mutineer::Result>] suppressed mutants.
    # @param source_map [Hash{String => String}] source text by file.
    # @param config [Mutineer::Config] run configuration.
    # @return [Array(Array, Array<Mutineer::Result>, Integer), Array(Array, Array<Mutineer::Result>, nil)]
    #   the jobs to run, the ignored results to report, and the count before --since.
    def self.scope_since(jobs, ignored_results, source_map, config)
      return [jobs, ignored_results, nil] unless config.since

      # One pass, so git computes the changed lines once.
      ignored_entries = ignored_results.map { |r| [r.subject, r.mutation, r] }
      kept = filter_since(jobs + ignored_entries, source_map, config)
      kept_ignored, kept_jobs = kept.partition { |entry| entry.last.is_a?(Result) }
      [kept_jobs, kept_ignored.map(&:last), jobs.size + ignored_results.size]
    end

    # --since: keep only jobs whose mutation lands on a line changed since the git
    # ref. Composes with coverage selection (it only narrows the job list; each
    # surviving mutant still goes through Runner.run's coverage check). A file with
    # no changed lines (absent from the diff) contributes no jobs. Line is computed
    # exactly as Runner.run does, from the already-read source in source_map.
    def self.filter_since(jobs, source_map, config)
      changed = ChangedLines.for(ref: config.since, files: config.sources,
                                 project_root: config.project_root)
      jobs.select do |subject, mutation|
        source = source_map[subject.file]
        line = source.byteslice(0, mutation.start_offset).count("\n") + 1
        abs = File.expand_path(subject.file, config.project_root)
        changed.fetch(abs, []).include?(line)
      end
    end

    # For each test file, the directory to add to $LOAD_PATH so its
    # `require "test_helper"` (or spec_helper) resolves: the nearest ancestor
    # holding that helper, plus the file's own dir as a fallback.
    def self.test_load_roots(test_files)
      test_files.flat_map do |f|
        dir = File.dirname(f)
        root = nil
        loop do
          if File.exist?(File.join(dir, "test_helper.rb")) || File.exist?(File.join(dir, "spec_helper.rb"))
            root = dir
            break
          end
          parent = File.dirname(dir)
          break if parent == dir

          dir = parent
        end
        [root, File.dirname(f)].compact
      end.uniq
    end

    # The unique absolute directories holding the sources. Sweep target for both
    # orphan mechanisms (in-process mutant tempfiles and external backup files),
    # and shipped to the daemon via {DaemonBackend.boot_config} so it can sweep too.
    # Shared so the path-expansion rule cannot drift between the paths.
    #
    # @param config [Mutineer::Config] run configuration.
    # @return [Array<String>] unique absolute source directories.
    def self.source_dirs(config)
      config.sources.map { |f| File.dirname(File.expand_path(f, config.project_root)) }.uniq
    end

    # Removes stale mutant tempfiles from the given directories. The daemon writes a
    # differently-named temp, so {DaemonBackend} passes its glob when it has to sweep
    # tool-side (nothing boots on an empty run, so the daemon's own sweep never runs).
    #
    # @param dirs [Array<String>] directories to sweep.
    # @param glob [String] filename pattern to remove.
    # @return [void]
    def self.sweep_orphans(dirs, glob = "mutineer_mutant*.rb")
      dirs.each do |dir|
        Dir.glob(File.join(dir, glob)).each do |f|
          File.unlink(f) rescue nil # rubocop:disable Style/RescueModifier
        end
      end
    end
  end
end
