# frozen_string_literal: true

require_relative "test_helper"
require "minitest/mock"
require "tmpdir"

# #396: an in-process --since run whose changed lines hold no mutant returns
# before the coverage map. The map is what runs the unmutated suite, so a red
# suite must not fail the run, and a boot file must not load. The daemon
# (#81, DaemonBackendContractTest#test_an_empty_job_list_boots_nothing) and
# --test-command (#76, #test_an_empty_job_list_skips_the_external_smoke_check)
# already return before their own expensive step.
class SinceEmptyRunTest < Minitest::Test
  OPS = ["arithmetic"].freeze

  # The rule, across the diffs that hold no arithmetic mutant and both
  # in-process shapes: standalone (CoverageMap#build_or_load, reload) and
  # boot (CoverageMap#build_via_fork), for reload and for redefine (the
  # --rails --no-daemon shape).
  def test_since_with_no_mutant_on_a_changed_line_skips_the_coverage_map
    with_repo do |dir, src, test, marker|
      boot, boot_marker = raising_boot(dir)
      original = File.read(src)
      [nil, boot].each do |boot_path|
        %w[reload redefine].each do |strategy|
          %i[clean comment other_line].each do |diff|
            label = "#{boot_path ? 'boot' : 'standalone'} #{strategy} #{diff}"
            File.write(src, apply_diff(original, diff))
            File.delete(marker) if File.exist?(marker)
            File.delete(boot_marker) if File.exist?(boot_marker)
            assert_diff_lines(dir, src, diff, label)

            config = run_config(dir, src, test, strategy: strategy, boot: boot_path)
            aggregate = extras = nil
            _out, err = capture_io do
              aggregate, _source_map, extras = refute_coverage_built { Mutineer::Runner.execute(config) }
            end

            assert_equal unscoped_count(dir, src), extras[:unscoped_mutants], label
            assert_operator extras[:unscoped_mutants], :>, 0, label
            assert_equal 0, aggregate.total, label
            assert_empty aggregate.results, label
            refute_path_exists marker, label
            refute_path_exists boot_marker, label
            refute_includes err, "not green", label
            refute_includes err, "must not boot", label
          end
        end
      end
    end
  end

  # A suppressed mutant on a changed line is still not a job. The run returns
  # that ignored result and does not build the map. DaemonBackend does the
  # same when jobs.empty? (#81).
  def test_since_with_only_a_suppressed_mutant_skips_the_coverage_map
    with_repo do |dir, src, test, marker|
      File.write(src, apply_diff(File.read(src), :suppress))
      assert_diff_lines(dir, src, :suppress, "suppress")
      expected = scoped_ids(dir, [src])
      assert_empty expected[:jobs], "the suppressed mutant must not be a job"
      refute_empty expected[:ignored], "the suppressed mutant stays in the report"

      config = run_config(dir, src, test)
      aggregate = nil
      refute_coverage_built do
        aggregate, = Mutineer::Runner.execute(config)
      end

      assert_equal expected[:ignored], aggregate.results.map(&:id)
      assert_equal 1, aggregate.ignored_count
      refute_path_exists marker
    end
  end

  # The sweep stays in front of the early return. An empty run creates no
  # mutant file, and one a previous run left behind is still removed (#253).
  def test_empty_since_run_still_sweeps_orphaned_mutant_files
    with_repo do |dir, src, test, _marker|
      orphan = File.join(dir, "mutineer_mutant20260101-#{unused_pid}-abcdef.rb")
      File.write(orphan, "class SinceCalc; end\n")
      config = run_config(dir, src, test)
      refute_coverage_built { Mutineer::Runner.execute(config) }
      refute_path_exists orphan
    end
  end

  # A missing boot or --require is a usage error on the empty path too.
  # The check does not load the file, and it does not build the map.
  def test_empty_since_run_still_rejects_a_missing_boot_or_require
    with_repo do |dir, src, test, marker|
      File.write(File.join(dir, "boot.rb"), "# present\n")
      {
        "missing_boot.rb" => run_config(dir, src, test, boot: "missing_boot.rb"),
        "missing_require.rb" => run_config(dir, src, test, boot: "boot.rb",
                                           require_paths: ["missing_require.rb"])
      }.each do |missing, config|
        error = assert_raises(Errno::ENOENT, missing) do
          refute_coverage_built { Mutineer::Runner.execute(config) }
        end
        assert_includes error.message, missing
        refute_path_exists marker, missing
      end
    end
  end

  # Without --since, an empty job list still builds the map and still rejects
  # a red suite. The early return is the --since case only.
  def test_run_without_since_still_checks_a_red_suite_when_no_mutant_exists
    with_repo do |dir, src, test, marker|
      config = run_config(dir, src, test, since: nil, operators: ["regex"])
      built = false
      real_new = Mutineer::CoverageMap.method(:new)
      capture_subprocess_io do
        Mutineer::CoverageMap.stub(:new, ->(**kwargs) {
          built = true
          real_new.call(**kwargs)
        }) do
          error = assert_raises(Mutineer::SmokeCheckError) { Mutineer::Runner.execute(config) }
          assert_includes error.message, "not green"
        end
      end
      assert built, "a run without --since must build the coverage map"
      assert_path_exists marker
    end
  end

  # A changed line that holds a mutant keeps the old order: boot, map, then
  # the clean check. Standalone and boot+redefine are the two map builders.
  def test_since_with_a_mutant_on_a_changed_line_still_checks_the_suite
    with_repo do |dir, src, test, marker|
      boot, boot_marker = quiet_boot(dir)
      File.write(src, apply_diff(File.read(src), :mutant_line))
      assert_diff_lines(dir, src, :mutant_line, "mutant line")
      [[nil, "reload"], [boot, "redefine"]].each do |boot_path, strategy|
        label = boot_path ? "boot redefine" : "standalone reload"
        File.delete(marker) if File.exist?(marker)
        File.delete(boot_marker) if File.exist?(boot_marker)
        config = run_config(dir, src, test, strategy: strategy, boot: boot_path)
        built = false
        real_new = Mutineer::CoverageMap.method(:new)
        capture_subprocess_io do
          Mutineer::CoverageMap.stub(:new, ->(**kwargs) {
            built = true
            real_new.call(**kwargs)
          }) do
            error = assert_raises(Mutineer::SmokeCheckError, label) { Mutineer::Runner.execute(config) }
            assert_includes error.message, "not green", label
          end
        end
        assert built, label
        assert_path_exists marker, label
        assert_path_exists boot_marker, label if boot_path
      end
    end
  end

  # Without a boot, an empty --since run still loads each source and
  # --require. A file that raises stays a runtime error. The coverage map
  # is not built.
  def test_empty_since_without_boot_still_reports_a_source_or_require_that_raises
    with_repo do |dir, src, test, marker|
      File.write(src, "raise \"source blew up\"\n")
      error = nil
      capture_io do
        error = assert_raises(Mutineer::ProjectLoadError) do
          refute_coverage_built { Mutineer::Runner.execute(run_config(dir, src, test)) }
        end
      end
      assert_includes error.message, "source blew up"
      refute_path_exists marker
    end

    with_repo do |dir, src, test, marker|
      require_path = File.join(dir, "setup.rb")
      File.write(require_path, "raise \"require blew up\"\n")
      config = run_config(dir, src, test, require_paths: [require_path])
      error = nil
      capture_io do
        error = assert_raises(Mutineer::ProjectLoadError) do
          refute_coverage_built { Mutineer::Runner.execute(config) }
        end
      end
      assert_includes error.message, "require blew up"
      refute_path_exists marker
    end
  end

  # A nonempty preview warns before the boot. A boot that then raises still
  # shows the git-diff skip. The collection after the map never runs.
  def test_since_diff_warning_prints_before_a_boot_that_raises
    with_repo do |dir, src, test, _marker|
      boot, = quiet_boot(dir)
      File.write(boot, "raise \"must not boot\"\n")
      generated = File.join(dir, "generated.rb")
      File.write(File.join(dir, ".gitignore"), "generated.rb\n")
      git(dir, "add", ".gitignore")
      git(dir, "commit", "-qm", "ignore generated")
      File.write(generated, "class Generated\n  def add(a, b)\n    a + b\n  end\nend\n")
      File.write(src, apply_diff(File.read(src), :mutant_line))
      _out, err = capture_io do
        error = assert_raises(Mutineer::ProjectLoadError) do
          Mutineer::Runner.execute(run_config(dir, [src, generated], test, boot: boot))
        end
        assert_includes error.message, "must not boot"
      end
      assert_equal 1, err.scan("is ignored by Git").size, err
    end
  end

  # #396 review: an unknown disable-line operator warns once. The preview
  # collects silently. The collection the run keeps is the one that warns:
  # the second pass when the diff holds no mutant, and the pass after the
  # map when a mutant remains.
  def test_unknown_disable_line_operator_warns_once
    with_repo do |dir, src, test, _marker|
      File.write(src, apply_diff(File.read(src), :bad_marker))
      File.write(test, passing_test(src))
      aggregate = nil
      _out, err = capture_subprocess_io do
        aggregate, = Mutineer::Runner.execute(run_config(dir, src, test))
      end
      assert_equal 1, err.scan('unknown operator "arithmetc"').size, err
      assert_equal 1, aggregate.killed_count
    end

    with_repo do |dir, src, test, marker|
      File.write(src, apply_diff(File.read(src), :bad_marker))
      git(dir, "add", "calc.rb")
      git(dir, "commit", "-qm", "bad marker")
      File.write(src, File.read(src).sub("class SinceCalc\n", "class SinceCalc\n  # note\n"))
      _out, err = capture_io do
        refute_coverage_built { Mutineer::Runner.execute(run_config(dir, src, test)) }
      end
      assert_equal 1, err.scan('unknown operator "arithmetc"').size, err
      refute_path_exists marker
    end
  end

  # A non-empty --since run collects again after the map, so ids match that
  # collection, and a git-diff warning from the silent preview is not repeated.
  def test_since_with_mutants_warns_once_and_keeps_collect_jobs_ids
    with_repo do |dir, src, test, _marker|
      generated = File.join(dir, "generated.rb")
      File.write(File.join(dir, ".gitignore"), "generated.rb\n")
      git(dir, "add", ".gitignore")
      git(dir, "commit", "-qm", "ignore generated")
      File.write(generated, <<~RUBY)
        class Generated
          def add(a, b)
            a + b
          end
        end
      RUBY
      File.write(src, apply_diff(File.read(src), :mutant_line))
      File.write(test, passing_test(src))
      expected = scoped_ids(dir, [src, generated])
      refute_empty expected[:jobs], "the touched arithmetic line must stay in the run"
      config = run_config(dir, [src, generated], test)
      aggregate = nil
      _out, err = capture_subprocess_io do
        aggregate, = Mutineer::Runner.execute(config)
      end
      assert_equal 1, err.scan("is ignored by Git").size, err
      assert_equal expected[:jobs], aggregate.results.reject(&:ignored?).map(&:id)
      assert_equal expected[:jobs].size, aggregate.killed_count
      assert_equal 0, aggregate.ignored_count
    end
  end

  def with_repo
    Dir.mktmpdir("mutineer-since-empty") do |dir|
      src = File.join(dir, "calc.rb")
      test = File.join(dir, "calc_test.rb")
      marker = File.join(dir, "ran.txt")
      File.write(src, <<~RUBY)
        class SinceCalc
          def add(a, b)
            a + b
          end

          def label
            "name"
          end
        end
      RUBY
      File.write(test, red_test(marker))
      git(dir, "init", "-q")
      git(dir, "config", "user.email", "t@t")
      git(dir, "config", "user.name", "t")
      git(dir, "add", ".")
      git(dir, "commit", "-qm", "base")
      yield dir, src, test, marker
    end
  end

  def git(dir, *args)
    assert system("git", "-C", dir, *args, out: File::NULL, err: File::NULL), "git #{args.join(' ')}"
  end

  def red_test(marker)
    <<~RUBY
      require "minitest/autorun"
      require_relative "calc"
      class SinceCalcTest < Minitest::Test
        def test_adds
          File.write(#{marker.dump}, "ran")
          flunk "red suite"
        end
      end
    RUBY
  end

  def passing_test(src)
    name = File.basename(src, ".rb")
    <<~RUBY
      require "minitest/autorun"
      require_relative #{name.dump}
      class SinceCalcTest < Minitest::Test
        def test_adds
          assert_equal 5, SinceCalc.new.add(2, 3)
        end
      end
    RUBY
  end

  def raising_boot(dir)
    marker = File.join(dir, "booted.txt")
    path = File.join(dir, "boot.rb")
    File.write(path, "File.write(#{marker.dump}, \"booted\")\nraise \"must not boot\"\n")
    [path, marker]
  end

  def quiet_boot(dir)
    marker = File.join(dir, "booted.txt")
    path = File.join(dir, "boot.rb")
    File.write(path, "File.write(#{marker.dump}, \"booted\")\n")
    [path, marker]
  end

  def apply_diff(text, diff)
    case diff
    when :clean then text
    when :comment then text.sub("class SinceCalc\n", "class SinceCalc\n  # note\n")
    when :other_line then text.sub('"name"', '"title"')
    when :mutant_line then text.sub("a + b", "a + b # touched")
    when :suppress then text.sub("a + b", "a + b # mutineer:disable-line")
    when :bad_marker then text.sub("a + b", "a + b # mutineer:disable-line arithmetc")
    else flunk("unknown diff #{diff}")
    end
  end

  # The fixture's contract: these diffs do, or do not, touch the arithmetic line.
  def assert_diff_lines(dir, src, diff, label)
    text = File.read(src)
    plus = line_no(text, "a + b")
    changed = changed_lines(dir, src)
    case diff
    when :clean
      assert_empty changed, label
    when :comment
      refute_includes changed, plus, label
      assert_includes changed, line_no(text, "# note"), label
    when :other_line
      refute_includes changed, plus, label
      assert_includes changed, line_no(text, '"title"'), label
    when :mutant_line, :suppress
      assert_includes changed, plus, label
    else
      flunk("unknown diff #{diff}")
    end
  end

  def changed_lines(dir, src)
    Mutineer::ChangedLines.for(ref: "HEAD", files: [src], project_root: dir)
                          .fetch(File.expand_path(src, dir))
  end

  def line_no(text, fragment)
    index = text.lines.index { |line| line.include?(fragment) }
    flunk "no line contains #{fragment}" unless index

    index + 1
  end

  def unscoped_count(dir, src)
    jobs, ignored, = Mutineer::JobPlan.collect_jobs(plain_config(dir, src), operators)
    jobs.size + ignored.size
  end

  def scoped_ids(dir, sources)
    config = plain_config(dir, sources, since: "HEAD")
    jobs, ignored, source_map, extras = Mutineer::JobPlan.collect_jobs(config, operators)
    capture_io do
      jobs, ignored, = Mutineer::JobPlan.scope_since(jobs, ignored, source_map, config, extras: extras)
    end
    { jobs: jobs.map(&:last), ignored: ignored.map(&:id) }
  end

  def operators
    Mutineer::MutatorRegistry.resolve(OPS)
  end

  def plain_config(dir, sources, since: nil, operators: OPS)
    Mutineer::Config.new(sources: Array(sources), project_root: dir, since: since, operators: operators)
  end

  def run_config(dir, sources, test, strategy: "reload", boot: nil, since: "HEAD", operators: OPS,
                 require_paths: [])
    Mutineer::Config.new(
      sources: Array(sources), tests: [test], project_root: dir, since: since,
      operators: operators, strategy: strategy, boot: boot, jobs: 1,
      cache_dir: File.join(dir, "cache"), framework: "minitest", require_paths: require_paths
    )
  end

  def refute_coverage_built
    Mutineer::CoverageMap.stub(:new, ->(**) { flunk "built the coverage map (#396)" }) do
      Mutineer::JobPlan.stub(:abort_if_unclean!, ->(*_args, **_kwargs) {
        flunk "checked the unmutated suite (#396)"
      }) do
        yield
      end
    end
  end
end
