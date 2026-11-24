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
require_relative "isolation"
require_relative "test_runners"
require_relative "orphan_guard"

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
    # Each mutant also gets its old-format id ({MutantId.legacy_for}), so an ignore
    # entry stored before ids carried the path still suppresses it. Prints nothing:
    # the extras hash returns, as data, `legacy_ignore_matches` (each old-format
    # ignore entry that matched a mutant through its old-format id => one
    # `{id:, file:, subject:}` hash per matched mutant, in collection order: its
    # new id, its project-relative file and its subject's qualified name;
    # recorded even when a new id is also listed, since the old entry still
    # over-matches other files), `id_map` (every reported mutant's new id =>
    # its old-format id), `dropped_id_map` (the same for each dropped repeat of
    # an edit: its id is still current for `mutineer migrate`), `copies` (each
    # kept mutant's id => the ids dropped as repeats of that edit, in drop
    # order, #374) and `declined`
    # (operator name => count of candidates that operator found and did not
    # mutate, {Mutators::Base#declined}; only counts above zero, keys sorted).
    # The name is the {MutatorRegistry::ALL} key, or the class's `to_s` for an
    # operator outside the registry. `--only` narrows `declined`, and `--since`
    # does not: a declined candidate has no mutation to place on a line.
    #
    # The extras also hold `subjects` (how many methods were discovered, each
    # counted once across path spellings) and `unmutated_subjects` (#386): one
    # `{subject:, file:, line:}` hash per method the selected operators gave no
    # mutation, an empty method included, sorted by file, line and name. It is
    # decided before suppression and repeat removal, so a method whose mutants
    # are all ignored is not listed. `--only` narrows both; `--since` does not.
    #
    # Mutations are collected in {MutatorRegistry::ALL} order, whatever the
    # order of `operator_classes`. Two operators can give the same mutated
    # source (#275), and the copy of the registry-first operator is the one
    # that runs, so the kept copy and the run order do not depend on the
    # `--operators` order.
    #
    # Subjects sharing a qualified name in one file (two owner-less `def index`
    # in two DSL blocks) get a per-file ordinal in discovery order, so their ids
    # differ; the first one's ordinal is 0 and leaves its id unchanged.
    #
    # @param config [Mutineer::Config] run configuration.
    # @param operator_classes [Array<Class>] resolved operators.
    # @return [Array(Array, Array<Result>, Hash<String,String>, Hash{Symbol => Hash})]
    #   jobs, ignored, source_map, and extras (`:legacy_ignore_matches`,
    #   `:id_map`, `:dropped_id_map`, `:copies`, `:declined`, `:subjects`,
    #   `:unmutated_subjects`).
    def self.collect_jobs(config, operator_classes)
      # Registry order, so a repeat across operators keeps the registry-first
      # copy (#275). A class outside ALL goes last; ties keep the input order.
      rank = MutatorRegistry::ALL.values
      operator_classes = operator_classes.each_with_index
                                         .sort_by { |klass, i| [rank.index(klass) || rank.size, i] }
                                         .map(&:first)
      source_map = {}
      disabled_map = {}
      id_paths = {}
      # [file, qualified_name] => { declaration offset => ordinal }: keyed by the
      # declaration, so the same file discovered twice (two path spellings) reuses
      # its ordinal instead of minting a second id for the same mutant.
      name_decls = Hash.new { |h, k| h[k] = {} }
      ignore_set = config.ignore.to_set
      ignore_reasons = config.ignore_reasons || {}
      jobs = []
      ignored_results = []
      legacy_ignore_matches = {}
      id_map = {}
      dropped_id_map = {}
      # Kept id => dropped ids. Separate from dropped_id_map, which migrate
      # reads as dropped id => old-format id (#374).
      copies = {}
      declined = Hash.new(0)
      # [id_path, def offset] => nil, or the method's entry when it got no mutation.
      subjects = {}
      Project.discover(config.sources, only: config.only).each do |subject|
        source = (source_map[subject.file] ||= Parser.read(subject.file))
        disabled = (disabled_map[subject.file] ||= suppress_map(source, subject.file))
        # A repeated operator name runs once, so its declines count once.
        mutations = operator_classes.uniq.flat_map do |klass|
          operator = klass.new
          found = operator.mutations_for(subject, source)
          declined[MutatorRegistry::ALL.key(klass) || klass.to_s] += operator.declined
          found
        end
        id_path = (id_paths[subject.file] ||= ProjectPath.relative(subject.file, config.project_root))
        decls = name_decls[[id_path, subject.qualified_name]]
        loc = subject.def_node.location
        ordinal = (decls[loc.start_offset] ||= decls.size)
        # The first path spelling of a def wins; later spellings are the same method.
        key = [id_path, loc.start_offset]
        unless subjects.key?(key)
          # end_line is for --since narrowing (#420); the public list keeps
          # only subject/file/line.
          subjects[key] = {
            subject: subject.qualified_name, file: subject.file,
            line: loc.start_line, end_line: loc.end_line,
            unmutated: mutations.empty?
          }
        end
        ids = MutantId.for_subject(subject, source, mutations, path: id_path, subject_ordinal: ordinal)
        legacy_ids = MutantId.legacy_for_subject(subject, source, mutations)
        lines = mutations.map { |m| source.byteslice(0, m.start_offset).b.count("\n") + 1 }
        keys = result_keys(mutations, source, lines)
        # A repeat of an earlier edit on the same line, from any operator, is
        # dropped (#159, #275), separately among the run and the ignored
        # mutants, so an ignored copy never hides a copy that should run. The
        # dropped id stays current for migrate, and `copies` names it on the
        # kept mutant so a report can show it (#374).
        seen = { run: {}, ignored: {} }
        mutations.each_with_index do |mutation, i|
          id = ids[i]
          legacy = legacy_ids[i]
          ignored = suppressed?(mutation.operator, lines[i], [id, legacy], disabled, ignore_set)
          # An old entry still over-matches other files even when the new id is
          # listed too, so every old-entry match is reported for migration,
          # including a dropped copy's.
          if ignore_set.include?(legacy)
            (legacy_ignore_matches[legacy] ||= []) << { id: id, file: id_path, subject: subject.qualified_name }
          end
          bucket = seen[ignored ? :ignored : :run]
          if (kept_id = bucket[keys[i]])
            dropped_id_map[id] = legacy
            (copies[kept_id] ||= []) << id
            next
          end
          bucket[keys[i]] = id

          id_map[id] = legacy
          if ignored
            reason = suppression_reason(mutation.operator, lines[i], [id, legacy], disabled, ignore_reasons)
            ignored_results << Result.ignored.with(subject: subject, mutation: mutation, id: id, reason: reason)
          else
            jobs << [subject, mutation, id]
          end
        end
      end
      declined = declined.select { |_, count| count.positive? }.sort.to_h
      infos = subjects.values
      unmutated = public_unmutated(infos)
      [jobs, ignored_results, source_map, { legacy_ignore_matches: legacy_ignore_matches, id_map: id_map,
                                            dropped_id_map: dropped_id_map, copies: copies, declined: declined,
                                            subjects: infos.size, unmutated_subjects: unmutated,
                                            subject_ranges: infos }]
    end

    # The reportable `{subject, file, line}` rows for methods with no mutants.
    #
    # @api private
    # @param infos [Array<Hash>] internal subject rows from {collect_jobs}.
    # @return [Array<Hash>]
    def self.public_unmutated(infos)
      infos.select { |h| h[:unmutated] }
           .map { |h| { subject: h[:subject], file: h[:file], line: h[:line] } }
           .sort_by { |h| [h[:file], h[:line], h[:subject]] }
    end

    # One key per mutation; two mutations share a key exactly when they are on
    # the same line and give the same mutated source (one edit), from one
    # operator (#159) or two (#275). The caller drops a repeat after ids are
    # assigned. Only a group of same-line mutations can repeat, so only those
    # build a key from their text: the span from the group's earliest start to
    # its latest end, digested. Every other mutation gets a key of its own.
    #
    # @param mutations [Array<Mutineer::Mutation>] one subject's mutations.
    # @param source [String] the full, unmutated source.
    # @param lines [Array<Integer>] each mutation's line.
    # @return [Array<Object>] one key per mutation, in order.
    def self.result_keys(mutations, source, lines)
      keys = Array.new(mutations.size) { |i| i }
      mutations.each_index.group_by { |i| lines[i] }.each_value do |group|
        next if group.size < 2

        from = group.map { |i| mutations[i].start_offset }.min
        to = group.map { |i| mutations[i].end_offset }.max
        group.each do |i|
          m = mutations[i]
          span = "#{source.byteslice(from...m.start_offset)}#{m.replacement}#{source.byteslice(m.end_offset...to)}"
          keys[i] = [lines[i], Digest::SHA256.digest(span)]
        end
      end
      keys
    end

    # Aborts the run when coverage capture saw a red unmutated suite. Scoring
    # those results would treat existing assertion failures as killed mutants.
    #
    # @param coverage_map [Mutineer::CoverageMap] the built or loaded map.
    # @param framework [String, nil] the run's framework (nil is Minitest, as in
    #   {TestRunners.for}). The message names the seed: an order-dependent
    #   suite can pass in a random order and fail in the pinned one (#282).
    # @return [void]
    # @raise [Mutineer::SmokeCheckError] when any captured test failed clean,
    #   or when no test recorded coverage and a capture failed.
    def self.abort_if_unclean!(coverage_map, framework: nil)
      if coverage_map.map.empty? && coverage_map.failed_test_files.any?
        raise SmokeCheckError, "no test recorded coverage, and capture failed for #{coverage_map.failed_test_files.join(', ')}"
      end

      files = coverage_map.failed_clean_tests
      return if files.empty?

      # A clean check that hit its deadline is not a red suite: no test failed,
      # so the seed hint does not apply.
      timeouts = (coverage_map.clean_timeouts || {}).slice(*files)
      files -= timeouts.keys
      raise SmokeCheckError, clean_timeout_message(timeouts) if files.empty?

      seed_hint = seed_hint_for(framework)
      # The hint opens with "the unmutated suite is not green", so the files
      # follow it rather than repeat that sentence (#360). Failure names and
      # the first error follow when capture stored them. A check that timed
      # out next to a red file is named too, so one run reports both.
      also = timeouts.empty? ? "" : " Also, #{clean_timeout_message(timeouts)}"
      detail = clean_failure_detail(coverage_map, files)
      raise SmokeCheckError,
            "#{ExternalBackend.generic_env_hint}. Failed: #{files.join(', ')}.#{seed_hint}#{also}#{detail}"
    end

    # Says which clean checks hit their deadline and how to raise it. It names
    # the longest deadline that passed: the combined check's deadline can be
    # above --capture-timeout, so any lower value would change nothing.
    #
    # @api private
    # @param timeouts [Hash{String => Numeric}] {CoverageMap#clean_timeouts}.
    # @return [String]
    def self.clean_timeout_message(timeouts)
      checks = timeouts.map do |rel, seconds|
        what = rel == "combined suite" ? "the combined clean check (the clean-check test files in one process)" : rel
        "#{what} timed out after #{seconds}s"
      end
      "the unmutated suite did not finish: #{checks.join('; ')}. " \
        "Mutineer stopped it, so it reports no failing test. " \
        "Set --capture-timeout (capture_timeout in the config) above #{timeouts.values.max}."
    end

    # Joins capped failure reports for the unclean files (#360).
    #
    # @api private
    # @param coverage_map [Mutineer::CoverageMap]
    # @param files [Array<String>]
    # @return [String] a leading newline plus the reports, or empty.
    def self.clean_failure_detail(coverage_map, files)
      details = coverage_map.failed_clean_details || {}
      parts = files.filter_map do |file|
        text = details[file].to_s.strip
        next if text.empty?

        "#{file}:\n#{text}"
      end
      return "" if parts.empty?

      text = parts.join("\n")
      limit = CoverageMap::CLEAN_FAILURE_DETAIL_LIMIT
      return "\n#{text}" if text.length <= limit

      "\n#{text[0, limit].rstrip}\n…"
    end

    # The not-green hint for this framework, or empty when it has no seed.
    #
    # @api private
    # @param framework [String, nil]
    # @return [String]
    def self.seed_hint_for(framework)
      # `==`, not `case`: `when` uses Module#===, and a module is not an
      # instance of itself.
      runner = TestRunners.for(framework)
      if runner == TestRunners::Minitest
        minitest_seed_hint
      elsif runner == TestRunners::RSpec
        rspec_seed_hint
      else
        ""
      end
    end

    # Names the configured seed, and accounts for helper overrides.
    #
    # @api private
    # @return [String]
    def self.minitest_seed_hint
      seed = MinitestIntegration.seed
      " Mutineer runs Minitest with SEED=#{seed}, unless a test helper changes SEED. " \
        "An order-dependent test can fail here and pass in another order. " \
        "Check the listed test files with the same seed and helpers " \
        "(for \"combined suite\", all of them together). " \
        "Change SEED, including helper settings, to choose another order."
    end

    # Names the seed a random RSpec order uses. A defined order is unchanged.
    #
    # @api private
    # @return [String]
    def self.rspec_seed_hint
      seed = TestRunners::RSpecSeed.advertised_seed
      " Mutineer runs a random RSpec order with seed #{seed}, unless you set a seed " \
        "(--seed, --order rand:N, SPEC_OPTS, .rspec, or config.seed). " \
        "RSpec reads SPEC_OPTS after the command line, so a seed there replaces " \
        "--seed on the rspec command. " \
        "A defined order is left as it is. " \
        "An order-dependent example can fail here and pass in another order. " \
        "Check the listed spec files with the same seed."
    end

    # The reload mutant text for a def in a concern's `included` or `prepended`
    # block (#297): the mutated file with one statement added just before the
    # hook call, `::Mutineer::ConcernBlocks.store_hook_def do <mutated def> end`.
    # The statement sits in the same body as the hook call, so the stored def has
    # the block's constant scope. The child passes the hook-def values to
    # {ConcernBlocks.load_mutant}, which places the def when the load reaches
    # that statement (#348). Shared by {Runner.run} and
    # {DaemonBackend.job_result}, so both build the same text. The hook call starts
    # before the def, so the mutation does not move its offset. A bad insert is
    # not checked here: the child's `load` raises `SyntaxError` before any test
    # runs, so the mutant scores `error`.
    #
    # @param mutated [String] the mutated source text.
    # @param mutation [Mutineer::Mutation] the mutation.
    # @param subject [Mutineer::Subject] a subject with a {Subject#reload_hook_call}.
    # @param source [String] the original source text.
    # @param reach_path [String, nil] sentinel for a `:maybe` mutant (#345).
    #   The placed def records a run of the mutated expression.
    # @param reach_key [String, nil] thread-local key for `reach_path`.
    # @return [Array(String, Hash{Symbol => Object})] the mutant text, and the
    #   original def's `line`, `name` and `singleton`.
    def self.hook_mutant(mutated, mutation, subject, source, reach_path: nil, reach_key: nil)
      at = subject.reload_hook_call.location.start_offset
      stored = "::Mutineer::ConcernBlocks.store_hook_def do\n" \
               "#{Isolation.mutated_def(mutation, subject, source, reach_path: reach_path, reach_key: reach_key)}\nend; "
      [mutated.byteslice(0...at) + stored + mutated.byteslice(at..),
       { line: subject.def_node.location.start_line, name: subject.name, singleton: subject.singleton }]
    end

    # The whole-file text the reload strategy loads for one mutant, shared by
    # {Runner.run} and {DaemonBackend.job_result} so both load the same text. A
    # def in a concern's hook block gets {hook_mutant}; any other mutant gets
    # the reach probe of a `:maybe` selection ({ReachProbe.wrap_mutation}).
    # Then each class statement whose superclass {kept_target} wraps keeps its
    # live superclass, and each superclass constant the file assigns keeps
    # its class ({keep_live_superclasses}, #492, #512, #503).
    #
    # @param mutated [String] the mutated source text.
    # @param mutation [Mutineer::Mutation] the mutation.
    # @param subject [Mutineer::Subject, nil] the subject being mutated.
    # @param source [String] the original source text.
    # @param reach_path [String, nil] sentinel for a `:maybe` mutant (#345).
    # @param reach_key [String, nil] fiber-local key for `reach_path`.
    # @return [Array(String, Hash{Symbol => Object}, nil)] the text to load, and
    #   the hook-def values of {hook_mutant}, or nil.
    def self.reload_code(mutated, mutation, subject, source, reach_path: nil, reach_key: nil)
      if subject&.reload_hook_call
        code, hook_def = hook_mutant(mutated, mutation, subject, source, reach_path: reach_path, reach_key: reach_key)
      else
        code = ReachProbe.wrap_mutation(mutated, mutation, reach_path, reach_key)
      end
      [keep_live_superclasses(code), hook_def]
    end

    # A new empty file for {ReloadGuards.callback_growth_log} (#479). The
    # caller deletes it after the run.
    #
    # @return [String] its path.
    def self.create_callback_growth_log
      file = Tempfile.create(["mutineer-callback-growth", ".log"])
      file.close
      file.path
    rescue SystemCallError => e
      # Report only (#479): a temp directory that refuses the file must not stop the run.
      warn "[mutineer] could not create the callback-growth log, so this run does not check " \
           "callback counts after a reload (#479): #{e.message}"
      nil
    end

    # The classes the mutant loads logged, each once, with a project-relative
    # file, in the order they were first logged. The log is read as bytes, so
    # a non-ASCII name or path does not raise when `LANG` is unset (#346).
    #
    # @param path [String, nil] the log file, or nil when the run had none.
    # @param project_root [String] the run's project root.
    # @return [Array<Array(String, String)>] each class name and its source file.
    def self.callback_growth_rows(path, project_root)
      return [] unless path && File.exist?(path)

      # Each field is written with `String#dump`, so a newline or tab in a name
      # or a path cannot split a record.
      File.binread(path).split("\n".b).filter_map do |line|
        name, file = line.split("\t".b, 2)
        next unless file

        [FsPath.read(name.undump), ProjectPath.relative(FsPath.read(file.undump), project_root)]
      rescue RuntimeError # a line that is not two dumped strings
        nil
      end.uniq
    end

    # Wraps the superclass of each class statement whose superclass is not a
    # constant (`Data.define(...)`, `Struct.new(...)`, `Class.new(...)`,
    # `DelegateClass(...)`) in {ReloadGuards.kept_superclass}, so loading the
    # file over its classes reopens each one instead of raising "superclass
    # mismatch" (#492). For a superclass that sets a local
    # (`class Q < (base = Struct.new(:a))`), only the written value is wrapped,
    # so the local is still set, to the live superclass (#512). See
    # {kept_target} for the superclasses it leaves as written. It also wraps
    # the value of a constant that a class statement in the file inherits from
    # in {ReloadGuards.kept_constant} ({kept_constant_splice}, #503). The
    # wrapped text stays as it is, inside the block, and on its own lines, so
    # line numbers do not move. A wrap puts one expression in a block, and a
    # class inside a wrapped superclass or a kept value is not wrapped again. A bad wrap is not
    # checked here: the child's `load` raises `SyntaxError`, and the mutant
    # scores `error`. Text with no such class comes back unchanged.
    #
    # @param code [String] the reload text.
    # @return [String]
    def self.keep_live_superclasses(code)
      program = Parser.parse_string(code).value
      names = Project.superclass_constant_names(program)
      splices = []
      queue = [program]
      while (node = queue.shift)
        if node.is_a?(Prism::ClassNode) && (target = kept_target(node.superclass))
          splices << [target, "kept_superclass", superclass_scope(node.constant_path), node.constant_path.name]
          # The wrap skips the whole superclass expression, so a class inside it
          # is not wrapped again: two splices in one range would not parse.
          queue.concat([node.constant_path, node.body].compact)
        elsif (splice = kept_constant_splice(node, names))
          # A kept value does not run again, so nothing inside it is wrapped.
          splices << splice
        else
          queue.concat(node.compact_child_nodes)
        end
      end
      return code if splices.empty?

      splices.sort_by { |target, *| -target.location.start_offset }.reduce(code) do |text, (target, guard, scope, name)|
        loc = target.location
        inner = text.byteslice(loc.start_offset, loc.length)
        wrapped = "::Mutineer::ReloadGuards.#{guard}(#{scope}, #{name.inspect}) { #{inner} }"
        text.byteslice(0, loc.start_offset) + wrapped + text.byteslice(loc.end_offset..)
      end
    end

    # The splice that keeps a constant's value on reload (#503): a constant
    # write that {Project.kept_constant_write?} keeps, a class builder call
    # with literal arguments. `BaseRow = Struct.new(:v)` with
    # `class Row < BaseRow` keeps `BaseRow`'s class, so `Row` reopens with the
    # same parent. A `||=` write keeps its text (#529).
    #
    # @param node [Prism::Node]
    # @param names [Set<Symbol, String>] {Project.superclass_constant_names} of the file.
    # @return [Array(Prism::Node, String, String, Symbol), nil] the node to
    #   wrap, the guard, the scope text and the name; nil for any other node.
    def self.kept_constant_splice(node, names)
      return nil unless Project.kept_constant_write?(node, names)

      if node.is_a?(Prism::ConstantPathWriteNode)
        [node.value, "kept_constant", superclass_scope(node.target), node.target.name]
      else
        [node.value, "kept_constant", "::Module.nesting.first", node.name]
      end
    end

    # The part of a class statement's superclass that the reload text wraps,
    # or nil to keep the superclass as written. A constant is left alone: it
    # names the same class on each load. A bare variable read is left alone
    # too: an earlier line set it, that line runs again, and a kept parent
    # would differ from what the variable then holds, a silent false verdict
    # (#512). Both hold inside any number of parentheses (`(base)`). A read
    # deeper in the expression (`Class.new(base)`) is still wrapped (#533).
    # A plain local write (`base = v`, or `(base = v)` alone in
    # parentheses, or a chain `a = b = v`) gives the target of its value, so
    # the write stays outside the block and still sets the local (#512).
    # Any other superclass that sets a local is left alone, because the block
    # would scope that local away from a later line. Every other superclass is
    # wrapped whole.
    #
    # @param node [Prism::Node, nil] a class statement's superclass.
    # @return [Prism::Node, nil]
    def self.kept_target(node)
      return nil if node.nil?

      inner = node
      inner = inner.body.body.first while Project.sole_statement_parentheses?(inner)
      return nil if LEFT_AS_WRITTEN.any? { |type| inner.is_a?(type) }
      return nil if outer_block_parameter?(node)

      write = plain_local_write(node)
      return kept_target(write.value) if write

      writes_local?(node) ? nil : node
    end

    # The local write `node` is, alone or as the one statement of one pair of
    # parentheses, or nil.
    #
    # @param node [Prism::Node]
    # @return [Prism::LocalVariableWriteNode, nil]
    def self.plain_local_write(node)
      node = node.body.body.first if Project.sole_statement_parentheses?(node)
      node.is_a?(Prism::LocalVariableWriteNode) ? node : nil
    end

    # Whether `node` reads a numbered parameter (`_1`) or `it` that belongs to
    # a block around it. The wrap adds a block, so such a read would belong to
    # the wrap's block and change meaning, or not parse. A block inside `node`
    # that has its own numbered or `it` parameter is not searched.
    #
    # @param node [Prism::Node]
    # @return [Boolean]
    def self.outer_block_parameter?(node)
      return true if node.type == :it_local_variable_read_node
      return true if node.is_a?(Prism::LocalVariableReadNode) && node.name.match?(/\A_[1-9]\z/)
      return false if (node.is_a?(Prism::BlockNode) || node.is_a?(Prism::LambdaNode)) &&
                      %i[numbered_parameters_node it_parameters_node].include?(node.parameters&.type)

      node.compact_child_nodes.any? { |child| outer_block_parameter?(child) }
    end

    # The superclass nodes {kept_target} leaves as written: a constant, and a
    # read of a variable an earlier statement set (#512).
    LEFT_AS_WRITTEN = [Prism::ConstantReadNode, Prism::ConstantPathNode, Prism::LocalVariableReadNode,
                       Prism::InstanceVariableReadNode, Prism::ClassVariableReadNode,
                       Prism::GlobalVariableReadNode].freeze

    # Whether `node` sets a local variable of the scope it runs in. A block or
    # lambda can set an outer local, so the walk enters it and counts only
    # writes that reach past it. A def has its own scope and is not entered.
    #
    # @param node [Prism::Node]
    # @param level [Integer] the blocks and lambdas between `node` and that scope.
    # @return [Boolean]
    def self.writes_local?(node, level = 0)
      # Prism's `depth` counts the scopes between the write and its variable,
      # so a write inside `level` blocks reaches the file's scope at that depth.
      return node.depth >= level if LOCAL_WRITES.any? { |type| node.is_a?(type) }
      return false if node.is_a?(Prism::DefNode)

      inner = node.is_a?(Prism::BlockNode) || node.is_a?(Prism::LambdaNode) ? level + 1 : level
      node.compact_child_nodes.any? { |child| writes_local?(child, inner) }
    end

    # The Prism nodes that set a local variable.
    LOCAL_WRITES = [Prism::LocalVariableWriteNode, Prism::LocalVariableTargetNode,
                    Prism::LocalVariableOperatorWriteNode, Prism::LocalVariableOrWriteNode,
                    Prism::LocalVariableAndWriteNode].freeze

    # The module a class statement or a constant write defines its constant
    # in, as Ruby text that runs where the superclass or the value runs:
    # `::Module.nesting.first` for `class X`, the written parent for
    # `class A::X` and `A::X = ...`, and `::Object` for `class ::X` and `::X = ...`.
    #
    # @param path [Prism::ConstantReadNode, Prism::ConstantPathNode]
    #   the class or constant name.
    # @return [String]
    def self.superclass_scope(path)
      return "::Module.nesting.first" if path.is_a?(Prism::ConstantReadNode)

      path.parent ? path.parent.slice : "::Object"
    end

    # Coverage-based test selection, shared by the in-process ({Runner.run}) and daemon
    # paths so both narrow identically (score parity). Returns
    # `[:run, abs_test_paths]` when some test covers the mutant's line, in the
    # order of {CoverageMap#order_tests} (paired files, then cheapest), or
    # `[:verdict, Result]` (no_coverage / uncapturable) when none do. A line
    # Ruby does not count (a later line of a multi-line statement) uses the
    # tests that ran the statement that holds it ({StatementLines}). When those
    # lines give no tests, it retries with the loose lines of the statement:
    # code of the statement that runs only sometimes (the right side of a
    # multi-line `a && b`, #254), and a first or last line that holds other
    # code (the opener of a one-line block, #289), but never the `def` line.
    # Those tests may not have run the mutant, so the answer is
    # `[:maybe, abs_test_paths]`. {selection_verdict} keeps a survivor that
    # the probe saw run, and leaves one it did not see as no_coverage (#345).
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
    # @return [Array(Symbol, Object)] `[:run, Array<String>]`, `[:maybe, Array<String>]`
    #   or `[:verdict, Result]`.
    def self.coverage_selection(source_file, mutation, subject, source, coverage_map)
      line   = source.byteslice(0, mutation.start_offset).b.count("\n") + 1
      chosen = coverage_map.tests_for(source_file, line)
      kind   = :run
      if chosen.empty? && subject
        # A multi-line statement has a count on one of its lines only.
        lines = StatementLines.for(subject.def_node, source, mutation.start_offset)
        chosen = lines.flat_map { |l| coverage_map.tests_for(source_file, l) }.uniq
        if chosen.empty?
          lines = StatementLines.for(subject.def_node, source, mutation.start_offset, loose: true)
          chosen = lines.flat_map { |l| coverage_map.tests_for(source_file, l) }.uniq
          kind = :maybe
        end
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

      # The clean checks name each test by its real path (ProjectPath.absolute).
      # A random RSpec order hashes that name, so a mutant run uses the same
      # spelling, or a symlinked root (/var on macOS) reorders the examples (#282).
      [kind, coverage_map.order_tests(source_file, chosen).map { |t| ProjectPath.absolute(t, coverage_map.project_root) }]
    end

    # The verdict of a mutant whose tests {coverage_selection} chose as `:maybe`:
    # they ran its statement but may not have run the mutated code. A kill is a
    # real kill. A survivor the probe saw run is a real survivor and keeps its
    # `--matrix` row (#345). A survivor the probe did not see is no_coverage,
    # the same as any other unreached mutant, and has no `--matrix` row (#254).
    # An error or a timeout stays what it is: the mutant ran, and a failure is
    # reported, not hidden. A kill keeps its whole `--matrix` row. A result of
    # any other selection comes back unchanged.
    #
    # @param kind [Symbol, nil, false] the first element of {coverage_selection}'s
    #   answer, or a falsy value when no selection ran.
    # @param result [Mutineer::Result] the mutant's verdict.
    # @param reached [Boolean] true when the mutated expression ran in the child.
    # @return [Mutineer::Result]
    def self.selection_verdict(kind, result, reached: false)
      return result unless kind == :maybe && result.survived? && !reached

      result.with(status: :no_coverage, kills: nil)
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
    # A `define_method` or `define_singleton_method` call stores its block.
    # Reloading the method does not run the class that already called it, such
    # as `Greeter` calling `greets`, so a mutant in that call or in the stored
    # block is the original method when the call's line ran at load (#435).
    # The line of `each` on an empty array counts without the block, so a block
    # that is not one of those calls is not `ran_at_load` here (#286). The
    # reach probe decides it ({stored_block_verdict}, #493). Re-running the
    # caller's class body is #389. `CI` is not read here. Rails eager load,
    # which the test env turns on when `CI` is set, is what puts the line in
    # the load set.
    #
    # A one-line or endless def keeps its body on the `def` line, so it uses
    # the method's own call count at load instead (#209), for code that runs
    # each time the method does ({StatementLines.runs_with_method?}). A block
    # on that `def` line is unchanged (#389).
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
      ran = lambda do |lines|
        lines.any? { |l| l != def_line && body.cover?(l) && coverage_map.ran_at_load?(source_file, l) }
      end
      return true if ran.call(StatementLines.for(subject.def_node, source, mutation.start_offset))

      ran.call(StatementLines.stored_method_lines(subject.def_node, source, mutation.start_offset))
    end

    # Whether the reach probe decides the survivor verdict of this mutant
    # (#493): its selection is `:run`, and a block or lambda literal around it
    # sits in a statement whose line ran at load. A class macro stores such a
    # block when the caller's class loads, before the mutant is applied. The
    # tests then run the stored original, and the mutant passes them all. The
    # syntax does not tell a stored block from one that runs at once (`each`),
    # so this is only a reason to add the probe. {stored_block_verdict} gives
    # the verdict.
    #
    # False for a `:maybe` selection: {selection_verdict} decides it (#254,
    # #345). False for a body on the `def` line: that line counts when the
    # method is defined (#389). False for a def that reload places from a
    # concern's hook block ({hook_mutant}): the probe is only in the placed
    # def, and a class that includes the concern during a test gets its def
    # from the file text, which has no probe. A test can run that def with
    # no word from the probe, so the probe is not evidence there (#507).
    #
    # @param kind [Symbol, nil, false] the first element of {coverage_selection}'s
    #   answer, or a falsy value when no selection ran.
    # @param source_file [String] the mutated source file path.
    # @param mutation [Mutineer::Mutation] the mutation.
    # @param subject [Mutineer::Subject, nil] the subject (for its method body range).
    # @param source [String] the original source text.
    # @param coverage_map [Mutineer::CoverageMap, nil] the coverage map.
    # @return [Boolean]
    def self.stored_block_candidate?(kind, source_file, mutation, subject, source, coverage_map)
      loc = subject&.body_loc
      return false unless kind == :run && loc && coverage_map && !subject.reload_hook_call

      def_line = subject.def_node.location.start_line
      return false if loc.end_line == def_line

      body = (loc.start_line..loc.end_line)
      StatementLines.enclosing_block_lines(subject.def_node, source, mutation.start_offset).any? do |l|
        l != def_line && body.cover?(l) && coverage_map.ran_at_load?(source_file, l)
      end
    end

    # A survivor in a block whose call ran at load becomes `ran_at_load` when
    # the probe was in the mutant's code and did not see the mutated
    # expression return during a test (#493): the tests ran a copy of the
    # block that the load stored, or did not run the mutated code. Any other
    # result comes back unchanged. A `--matrix` row is kept. The callers run
    # this after {load_verdict} and {selection_verdict}.
    #
    # @param result [Mutineer::Result] the mutant's verdict.
    # @param candidate [Boolean] the answer of {stored_block_candidate?}.
    # @param probed [Boolean] true when the code the child loaded holds a
    #   probe that can speak ({ReachProbe.conclusive?}). Without one there is
    #   no evidence, so the verdict stays.
    # @param reached [Boolean] true when the mutated expression returned
    #   during a test ({ReachProbe.reached?}).
    # @return [Mutineer::Result]
    def self.stored_block_verdict(result, candidate:, probed:, reached:)
      return result unless candidate && probed && result.survived? && !reached

      result.with(status: :ran_at_load)
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
        raw = comment.slice # an invalid byte in a comment is legal Ruby (#538)
        start = raw.b.index(/#\s*mutineer:disable-line/n)
        next unless start

        # The marker through the end of its operator list; an invalid byte after `--` is only the reason.
        head = raw.b.byteslice(start..).split(/\s--/n, 2).first.force_encoding(raw.encoding)
        unless head.valid_encoding?
          # An invalid byte before the reason could hide an operator name or cut the list: silence nothing.
          warn "mutineer: invalid byte in the disable-line marker at #{file}:#{line}; the marker is ignored"
          next
        end
        m = head.match(/#\s*mutineer:disable-line(?:\s+([\w,\s]+))?/)

        ops = m[1]&.split(",")&.map(&:strip)&.reject(&:empty?)
        # Only spaces or commas after the marker (e.g. `disable-line  -- why`)
        # is a bare marker, not an empty list that silences nothing.
        ops = nil if ops&.empty?
        unknown = ops.to_a.reject { |o| MutatorRegistry::ALL.key?(o) }
        unknown.each do |o|
          warn "mutineer: unknown operator #{o.inspect} in #{file}:#{line}#{Mutineer.did_you_mean(o, MutatorRegistry::ALL.keys)} " \
               "(known: #{MutatorRegistry::ALL.keys.join(', ')}); write a reason after --"
        end
        reason = raw.byteslice(start..).scrub[/\s--\s*(.*)\z/, 1]&.strip
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
    # (bare, or scoped to its operator), OR its new or old-format id is in the
    # config ignore list. Checked at job-build time so a suppressed mutant is
    # never forked.
    #
    # @param ids [Array<String>, String] the mutant's new id and its old-format
    #   id, or a single id (the pre-#126 call shape).
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
    # @param ids [Array<String>] the new id and the old-format id.
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

    # Counts scheduled mutants in each source pairing skipped.
    # One source is parsed at a time. A source that raises records nil and
    # an error string. This method prints nothing. The caller prints the error.
    # An empty job list counts 0. `--only` and `--since` narrow the count.
    # They do not drop the source. Ignored mutants are not in the count.
    # The count is not a validity check.
    #
    # The third element holds the id maps from those sources, taken before
    # `--since` narrows the count. A real run drops unpaired sources before
    # {collect_jobs}, so the unmatched-ignore check merges these maps back in
    # and agrees with a dry run of the same files (#377). A source that could
    # not be read contributes no ids.
    #
    # @param config [Mutineer::Config] run configuration. Reads `unpaired_sources`.
    # @param operator_classes [Array<Class>] resolved operators.
    # @return [Array(Hash{String => Integer, nil}, Array<Hash>, Hash)]
    #   file => count, in source order; `{file:, error:}` failures; and
    #   `{id_map:, dropped_id_map:, legacy_ignore_matches:}` for those sources.
    def self.unpaired_counts(config, operator_classes)
      counts = {}
      failures = []
      pending_jobs = []
      pending_ignored = []
      pending_map = {}
      pending_files = []
      id_map = {}
      dropped_id_map = {}
      legacy_ignore_matches = {}

      config.unpaired_sources.each do |file|
        copy = config.dup
        copy.sources = [file]
        begin
          jobs, ignored, source_map, file_extras = collect_jobs(copy, operator_classes)
        rescue StandardError => e
          counts[file] = nil
          failures << { file: file, error: "#{e.class}: #{e.message}" }
          next
        end
        id_map.merge!(file_extras[:id_map])
        dropped_id_map.merge!(file_extras[:dropped_id_map])
        file_extras[:legacy_ignore_matches].each do |old, hits|
          (legacy_ignore_matches[old] ||= []).concat(hits)
        end

        if jobs.empty? || !config.since
          counts[file] = jobs.size
        else
          pending_jobs.concat(jobs)
          pending_ignored.concat(ignored)
          pending_map.merge!(source_map)
          pending_files << file
          counts[file] = 0
        end
      end

      apply_unpaired_since!(counts, pending_jobs, pending_ignored, pending_map, pending_files, config) if config.since
      [counts, failures, { id_map: id_map, dropped_id_map: dropped_id_map,
                           legacy_ignore_matches: legacy_ignore_matches }]
    end

    # Replaces pending unpaired counts with the jobs `--since` keeps.
    # One {scope_since} call covers every file that produced a job.
    #
    # @api private
    # @param counts [Hash{String => Integer, nil}] file => count, updated in place.
    # @param jobs [Array] scheduled jobs from those files.
    # @param ignored [Array<Mutineer::Result>] suppressed mutants from those files.
    # @param source_map [Hash{String => String}] source text by file.
    # @param files [Array<String>] unpaired files that produced jobs.
    # @param config [Mutineer::Config] run configuration.
    # @return [void]
    def self.apply_unpaired_since!(counts, jobs, ignored, source_map, files, config)
      return if files.empty?

      copy = config.dup
      copy.sources = files
      kept, = scope_since(jobs, ignored, source_map, copy)
      tally = Hash.new(0)
      kept.each do |subject,|
        key = unpaired_path(subject.file, files, config.project_root)
        tally[key] += 1 if key
      end
      files.each { |file| counts[file] = tally[file] }
    end

    # The unpaired path spelling that names the same file as `subject_file`.
    #
    # @api private
    # @param subject_file [String] path stored on the subject.
    # @param files [Array<String>] unpaired paths in the caller's spelling.
    # @param project_root [String] root for relative paths.
    # @return [String, nil] the matching spelling, or nil.
    def self.unpaired_path(subject_file, files, project_root)
      absolute = File.expand_path(subject_file, project_root)
      files.find { |file| File.expand_path(file, project_root) == absolute }
    end

    # The test list a `--since` run with `since_paired_tests` uses (#496): the
    # tests paired with each source that still has a job, in the order of
    # `config.tests`. Returns `config.tests` itself when the run must keep its
    # full list: the setting is off, there is no `--since`, a `--coverage-from`
    # capture is reused (its test list must match, {coverage_from_reused?}),
    # `--baseline` is set (a narrowed run can turn a new survivor into
    # `no_coverage`, which the new-survivor check leaves out), pairing stored
    # no rows (an explicit `--test` list, or a caller that built its own
    # Config), there are no jobs, or a source with a job has no pairing row.
    # Reads only.
    #
    # @param config [Mutineer::Config] run configuration after pairing.
    # @param jobs [Array] (subject, mutation, id) entries after {scope_since}.
    # @return [Array<String>] the narrowed test list, or `config.tests`.
    def self.since_tests(config, jobs)
      return config.tests unless config.since && config.since_paired_tests && !coverage_from_reused?(config)
      return config.tests if config.baseline || config.tests_by_source.empty? || jobs.empty?

      rows = config.tests_by_source.keys
      wanted = Set.new
      jobs.map { |subject,| subject.file }.uniq.each do |file|
        key = unpaired_path(file, rows, config.project_root)
        return config.tests unless key

        config.tests_by_source.fetch(key).each { |test| wanted << File.expand_path(test, config.project_root) }
      end
      config.tests.select { |test| wanted.include?(File.expand_path(test, config.project_root)) }
    end

    # True when the run reuses a `--coverage-from` capture: an in-process
    # `--rails` or `--boot` run. Other runs ignore the flag (the CLI warns),
    # so it does not stop `since_paired_tests` there.
    #
    # @param config [Mutineer::Config] run configuration.
    # @return [Boolean]
    def self.coverage_from_reused?(config)
      !config.coverage_from.nil? && !config.boot.nil? && !config.daemon && config.test_command.nil?
    end

    # Applies {since_tests} for {Runner.execute} and {DaemonBackend.execute}.
    # Returns `config` itself when nothing narrows. Otherwise prints one stderr
    # line with the counts and returns a copy of `config` with the narrowed
    # test list. The source list is not narrowed, and the caller's config is
    # not changed, so the CLI still reports the whole run.
    #
    # @param config [Mutineer::Config] run configuration after pairing.
    # @param jobs [Array] (subject, mutation, id) entries after {scope_since}.
    # @return [Mutineer::Config] `config`, or a narrowed copy.
    def self.narrow_tests_for_since(config, jobs)
      tests = since_tests(config, jobs)
      return config if tests.size == config.tests.size

      live = jobs.map { |subject,| File.expand_path(subject.file, config.project_root) }.uniq.size
      warn since_narrowing_line(tests.size, config.tests.size, live, config.sources.size)
      narrowed = config.dup
      narrowed.tests = tests
      narrowed
    end

    # The stderr line of a narrowed `--since` run (#496).
    #
    # @param kept_tests [Integer] test files the run uses.
    # @param all_tests [Integer] test files pairing found.
    # @param live_sources [Integer] paired sources with a mutant on a changed line.
    # @param all_sources [Integer] paired sources.
    # @return [String]
    def self.since_narrowing_line(kept_tests, all_tests, live_sources, all_sources)
      verb = live_sources == 1 ? "has" : "have"
      "[mutineer] --since: running #{kept_tests} of #{all_tests} test files, the ones paired with the " \
        "#{live_sources} of #{all_sources} paired sources that #{verb} a mutant on a changed line. " \
        "A mutant that only another test reaches shows as survived or no_coverage, so a kill or a survivor can be missed. " \
        "no_coverage is outside the score, so a --threshold gate can pass where a full run fails: gate on a full run, " \
        "or add --baseline, which keeps every test."
    end

    # Narrows the jobs and the suppressed (ignored) results to --since when it
    # is set, as the dry run does, so a scoped report lists only mutants on
    # changed lines. Also returns how many mutants there were before narrowing
    # (nil without --since), so the CLI can tell "the changes held nothing to
    # test" from "nothing was mutable at all". When `extras` is given, also
    # narrows `subjects` / `unmutated_subjects` to methods whose def range
    # intersects the diff (#420), and drops `copies` whose kept mutant is out
    # of scope (#374).
    #
    # @param jobs [Array] (subject, mutation, id) entries to run.
    # @param ignored_results [Array<Mutineer::Result>] suppressed mutants.
    # @param source_map [Hash{String => String}] source text by file.
    # @param config [Mutineer::Config] run configuration.
    # @param extras [Hash, nil] {collect_jobs} extras to narrow in place.
    # @return [Array(Array, Array<Mutineer::Result>, Integer), Array(Array, Array<Mutineer::Result>, nil)]
    #   the jobs to run, the ignored results to report, and the count before --since.
    def self.scope_since(jobs, ignored_results, source_map, config, extras: nil)
      unless config.since
        extras&.delete(:subject_ranges)
        return [jobs, ignored_results, nil]
      end

      # One pass, so git computes the changed lines once for jobs and subjects.
      ignored_entries = ignored_results.map { |r| [r.subject, r.mutation, r] }
      range_files = extras&.fetch(:subject_ranges, [])&.map { |h| h[:file] } || []
      files = (config.sources + range_files).uniq
      changed = ChangedLines.for(ref: config.since, files: files, project_root: config.project_root)
      kept = filter_since(jobs + ignored_entries, source_map, config, changed: changed)
      kept_ignored, kept_jobs = kept.partition { |entry| entry.last.is_a?(Result) }
      if extras
        narrow_subjects_since!(extras, config, changed: changed)
        narrow_copies!(extras, kept_jobs, kept_ignored.map(&:last))
      end
      [kept_jobs, kept_ignored.map(&:last), jobs.size + ignored_results.size]
    end

    # Drops copy lists whose kept mutant `--since` removed (#374). A dropped
    # copy shares that mutant's line, so it leaves with the mutant.
    #
    # @api private
    # @param extras [Hash] {collect_jobs} extras.
    # @param kept_jobs [Array] jobs still in scope; each id is the last element.
    # @param kept_ignored [Array<Mutineer::Result>] ignored mutants still in scope.
    # @return [void]
    def self.narrow_copies!(extras, kept_jobs, kept_ignored)
      copies = extras[:copies]
      return unless copies

      keep = Set.new(kept_jobs.map(&:last))
      kept_ignored.each { |result| keep.add(result.id) }
      extras[:copies] = copies.select { |id, _list| keep.include?(id) }
    end

    # Keeps `subjects` / `unmutated_subjects` for methods whose def range
    # intersects `--since` changed lines (#420). Drops the internal
    # `subject_ranges` key afterward.
    #
    # @api private
    # @param extras [Hash] {collect_jobs} extras.
    # @param config [Mutineer::Config]
    # @param changed [Hash{String => Set<Integer>}, nil] precomputed map from
    #   {ChangedLines.for}; when nil, this method loads it for the range files.
    # @return [void]
    def self.narrow_subjects_since!(extras, config, changed: nil)
      ranges = extras.delete(:subject_ranges) || []
      return if ranges.empty?

      files = ranges.map { |h| h[:file] }.uniq
      changed ||= ChangedLines.for(ref: config.since, files: files, project_root: config.project_root)
      in_scope = ranges.select do |h|
        lines = changed.fetch(FsPath.expand(h[:file], config.project_root), Set.new)
        next false if lines.empty?

        (h[:line]..h[:end_line]).any? { |ln| lines.include?(ln) }
      end
      extras[:subjects] = in_scope.size
      extras[:unmutated_subjects] = public_unmutated(in_scope)
    end

    # --since: keep only jobs whose mutation lands on a line changed since the git
    # ref. Composes with coverage selection (it only narrows the job list; each
    # surviving mutant still goes through Runner.run's coverage check). A file with
    # no changed lines (absent from the diff) contributes no jobs. Line is computed
    # exactly as Runner.run does, from the already-read source in source_map.
    #
    # @param changed [Hash{String => Set<Integer>}, nil] precomputed map from
    #   {ChangedLines.for}; when nil, this method loads it for `config.sources`.
    def self.filter_since(jobs, source_map, config, changed: nil)
      changed ||= ChangedLines.for(ref: config.since, files: config.sources,
                                   project_root: config.project_root)
      jobs.select do |subject, mutation|
        source = source_map[subject.file]
        line = source.byteslice(0, mutation.start_offset).b.count("\n") + 1
        abs = FsPath.expand(subject.file, config.project_root)
        changed.fetch(abs, []).include?(line)
      end
    end

    # The `load_path` directories (#491), absolute, in the order the user wrote
    # them. Relative entries resolve against the project root. The runner,
    # the daemon boot config and the CLI check all read this one list. An
    # existing directory resolves through its symlinks, as CoverageMap's
    # capture subprocess resolves the same entry ({ProjectPath.absolute}), so
    # `link/../support` names one directory in every place.
    #
    # @param config [Mutineer::Config] run configuration.
    # @return [Array<String>] absolute directories; [] when none is set.
    def self.extra_load_dirs(config)
      config.extra_load_paths.map { |dir| ProjectPath.absolute(dir, config.project_root) }
    end

    # For each test file, the directory to add to $LOAD_PATH so its
    # `require "test_helper"` (or spec_helper) resolves: the nearest ancestor
    # holding that helper, plus the file's own dir as a fallback. A test under
    # the project's `packs/` folder with no helper above it also gets the `test/` or
    # `spec/` folder (`spec/` first for a `_spec.rb` file) of the nearest
    # ancestor that holds one, because a pack test requires the app's helper
    # by name (#494).
    #
    # @param test_files [Array<String>] absolute test paths.
    # @param project_root [String, nil] project root; nil skips the pack rule.
    # @return [Array<String>] unique absolute directories.
    def self.test_load_roots(test_files, project_root: nil)
      packs = project_root && "#{File.expand_path(project_root)}/packs/"
      test_files.flat_map do |f|
        root = helper_ancestor(File.dirname(f)) { |dir| helper_dir?(dir) ? dir : nil }
        if root.nil? && packs && f.start_with?(packs)
          names = f.end_with?("_spec.rb") ? %w[spec test] : %w[test spec]
          root = helper_ancestor(File.dirname(f)) do |dir|
            names.map { |name| File.join(dir, name) }.find { |sub| helper_dir?(sub) }
          end
        end
        [root, File.dirname(f)].compact
      end.uniq
    end

    # Walks from `dir` up to the filesystem root and returns the first
    # non-nil value the block gives for a directory.
    #
    # @param dir [String] absolute directory to start from.
    # @yieldparam dir [String] each directory on the way up.
    # @return [String, nil]
    def self.helper_ancestor(dir)
      loop do
        found = yield dir
        return found if found

        parent = File.dirname(dir)
        return nil if parent == dir

        dir = parent
      end
    end

    # True when `dir` holds `test_helper.rb` or `spec_helper.rb`.
    #
    # @param dir [String]
    # @return [Boolean]
    def self.helper_dir?(dir)
      File.exist?(File.join(dir, "test_helper.rb")) || File.exist?(File.join(dir, "spec_helper.rb"))
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

    # Removes stale mutant tempfiles from the given directories. The default
    # glob matches the files of both modes, so the in-process boot sweep also
    # removes an old daemon file (#287). {DaemonBackend} passes its daemon-only
    # glob when it sweeps tool-side at the end of every daemon run, empty or not.
    # A file another process still owns is left in place: both modes record the
    # creating pid in the name and lock the file while it loads (#295).
    #
    # @param dirs [Array<String>] directories to sweep.
    # @param glob [String] filename pattern to remove.
    # @return [Array<String>] the files left in place because a process owns them.
    def self.sweep_orphans(dirs, glob = OrphanGuard::TEMP_BASENAME)
      dirs.flat_map do |dir|
        Dir.glob(File.join(dir, glob)).select do |path|
          next true if OrphanGuard.mutant_file_in_use?(path)

          File.unlink(path) rescue nil # rubocop:disable Style/RescueModifier
          false
        end
      end
    end
  end
end
