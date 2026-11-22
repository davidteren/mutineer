# frozen_string_literal: true

require_relative "test_helper"
require "coverage"
require "json"
require "minitest/mock"
require "open3"
require "rbconfig"
require "tmpdir"
require "mutineer/config"
require "mutineer/runner"
require "mutineer/daemon_backend"

# #491: the load_path directories reach $LOAD_PATH by one rule in every place
# that loads a test: the in-process parent (its mutant forks inherit it), the
# capture subprocess of a run with no boot file, and the daemon. The test-helper
# roots come first, and the load_path directories keep the written order. With
# no boot file, `lib` comes before both. Each place is checked where the test
# file loads, by the $LOAD_PATH it sees and by which copy of a shared file it got.
class LoadPathTest < Minitest::Test
  # Directories that each hold a shared_name.rb; the first one on the path wins.
  EXTRA = %w[x1 x2 x3].freeze

  def setup
    @saved_load_path = $LOAD_PATH.dup
  end

  def teardown
    $LOAD_PATH.replace(@saved_load_path)
  end

  # A temp project whose test file logs one JSON line each time it loads.
  # `tag` keeps the source class and the probe names unique, since the
  # parent (this test process) requires some of them. A run without
  # load_path gets `source_probe: false`: its parent loads the source before
  # lib is on $LOAD_PATH, as in earlier versions.
  def with_project(tag, source_probe: true)
    Dir.mktmpdir("mutineer-load-path") do |dir|
      proj = File.realpath(dir)
      log = File.join(proj, "load.log")
      klass = "LoadPathCalc#{tag}"
      # The source loads lib_probe as it loads, so the parent's order before
      # the run matters too, not only the order when the tests load.
      probe = source_probe ? "require \"lib_probe_#{tag}\"\n" : ""
      write(proj, "lib/load_path_calc_#{tag}.rb", "#{probe}class #{klass}\n  def add(a, b)\n    a + b\n  end\nend\n")
      write(proj, "test/test_helper.rb", "require \"minitest/autorun\"\n")
      # In the test-helper root and in x1: the root copy must win.
      write(proj, "test/helper_probe_#{tag}.rb", "\n")
      write(proj, "x1/helper_probe_#{tag}.rb", "\n")
      EXTRA.each { |x| write(proj, "#{x}/shared_name.rb", "\n") }
      # In lib and in x1: with no boot file, lib comes first, so lib's copy wins.
      write(proj, "lib/lib_probe_#{tag}.rb", "\n")
      write(proj, "x1/lib_probe_#{tag}.rb", "\n")
      write(proj, "x2/boot_probe_#{tag}.rb", "\n")
      write(proj, "test/load_path_calc_#{tag}_test.rb", <<~RUBY)
        require "test_helper"
        require "shared_name"
        require "helper_probe_#{tag}"
        require "json"
        require_relative "../lib/load_path_calc_#{tag}"
        require "lib_probe_#{tag}"
        found = ->(name) { $LOADED_FEATURES.grep(%r{/\#{name}\\.rb\\z}).first }
        File.open(#{log.dump}, "a") do |f|
          f.puts JSON.generate("kind" => (defined?(Mutineer::Runner) ? "fork" : "subprocess"),
                               "path" => $LOAD_PATH, "shared" => found.("shared_name"),
                               "helper" => found.("helper_probe_#{tag}"),
                               "lib" => found.("lib_probe_#{tag}"))
        end
        class LoadPathCalc#{tag}Test < Minitest::Test
          def test_add
            assert_equal 5, #{klass}.new.add(2, 3)
          end
        end
      RUBY
      yield proj, log, tag
    end
  end

  def write(proj, rel, text)
    path = File.join(proj, rel)
    FileUtils.mkdir_p(File.dirname(path))
    File.write(path, text)
  end

  def config_for(proj, tag, extra:, boot: nil)
    Mutineer::Config.new(
      sources: [File.join(proj, "lib/load_path_calc_#{tag}.rb")],
      tests: [File.join(proj, "test/load_path_calc_#{tag}_test.rb")],
      project_root: proj, boot: boot, extra_load_paths: extra, jobs: 1, framework: "minitest",
      cache_dir: File.join(proj, ".mutineer"), strategy: "reload"
    )
  end

  def lines(log) = File.readlines(log).map { |line| JSON.parse(line) }

  # Asserts the relative order of `dirs` in `path`, each present.
  def assert_order(path, dirs, label)
    positions = dirs.map { |d| path.index(d) }
    refute_includes positions, nil, "#{label}: #{dirs.zip(positions).inspect}"
    assert_equal positions.sort, positions, "#{label}: #{dirs.zip(positions).inspect}"
  end

  def test_order_in_process_without_a_boot_file
    assert_order_without_a_boot_file("NoBoot")
  end

  # Bundler or RUBYOPT can put lib and the test root on $LOAD_PATH before the
  # run. They still come before the load_path directories in the parent, as
  # in the capture subprocess, which gets them from RUBYLIB here.
  def test_order_without_a_boot_file_when_lib_and_the_test_root_are_on_the_path
    assert_order_without_a_boot_file("Preset", preset: %w[lib test])
  end

  def assert_order_without_a_boot_file(tag, preset: [])
    with_project(tag) do |proj, log, _tag|
      dirs = preset.map { |d| File.join(proj, d) }
      $LOAD_PATH.push(*dirs)
      aggregate = nil
      with_env("RUBYLIB" => dirs.empty? ? ENV.fetch("RUBYLIB", nil) : dirs.join(File::PATH_SEPARATOR)) do
        aggregate, = Mutineer::Runner.execute(config_for(proj, tag, extra: %w[x1 x2 x3]))
      end

      assert_operator aggregate.killed_count, :>, 0
      kinds = lines(log).map { |l| l["kind"] }.uniq.sort
      assert_equal %w[fork subprocess], kinds, "the capture subprocess and a mutant fork both loaded the test"
      lines(log).each do |line|
        order = ["lib", "test", *EXTRA].map { |d| File.join(proj, d) }
        assert_order(line["path"], order, line["kind"])
        assert_equal File.join(proj, "x1/shared_name.rb"), line["shared"], line["kind"]
        assert_equal File.join(proj, "test/helper_probe_#{tag}.rb"), line["helper"], line["kind"]
        assert_equal File.join(proj, "lib/lib_probe_#{tag}.rb"), line["lib"], line["kind"]
      end
    end
  end

  def test_order_in_process_with_a_boot_file
    assert_order_with_a_boot_file("Boot")
  end

  # A test root already on $LOAD_PATH (RUBYOPT=-Itest) still comes first.
  def test_order_with_a_boot_file_when_the_test_root_is_on_the_path
    assert_order_with_a_boot_file("BootPreset", preset: true)
  end

  def assert_order_with_a_boot_file(tag, preset: false)
    with_project(tag) do |proj, log, _tag|
      $LOAD_PATH.push(File.join(proj, "test")) if preset
      # The boot file loads from a load_path directory, so the directories
      # are on $LOAD_PATH before it.
      # helper_probe is in the test root and in x1: the boot file must get the
      # root's copy, as in the daemon.
      write(proj, "boot.rb", "require \"boot_probe_#{tag}\"\nrequire \"helper_probe_#{tag}\"\n" \
                             "require_relative \"lib/load_path_calc_#{tag}\"\n")
      aggregate, = Mutineer::Runner.execute(config_for(proj, tag, extra: %w[x1 x2 x3], boot: "boot.rb"))

      assert_operator aggregate.killed_count, :>, 0
      refute_empty lines(log)
      lines(log).each do |line|
        assert_order(line["path"], ["test", *EXTRA].map { |d| File.join(proj, d) }, line["kind"])
        assert_equal File.join(proj, "x1/shared_name.rb"), line["shared"]
        assert_equal File.join(proj, "test/helper_probe_#{tag}.rb"), line["helper"]
      end
    end
  end

  # A `link/../support` entry names the directory the file system reaches
  # through the symlink, as the capture subprocess resolves it, not the one
  # `..` names as text. The parent and the subprocess must agree.
  def test_a_symlink_with_dot_dot_resolves_the_same_in_every_place
    with_project("Symlink") do |proj, log, tag|
      FileUtils.mkdir_p(File.join(proj, "shared/deep"))
      File.symlink(File.join(proj, "shared/deep"), File.join(proj, "link"))
      write(proj, "shared/support/shared_name.rb", "\n")
      write(proj, "support/shared_name.rb", "\n")
      aggregate, = Mutineer::Runner.execute(config_for(proj, tag, extra: %w[link/../support]))

      assert_operator aggregate.killed_count, :>, 0
      assert_equal %w[fork subprocess], lines(log).map { |l| l["kind"] }.uniq.sort
      assert_equal [File.join(proj, "shared/support/shared_name.rb")], lines(log).map { |l| l["shared"] }.uniq
    end
  end

  # Without the setting the test cannot load shared_name, so no capture
  # records coverage and the run stops before any mutant. With a boot file
  # and without one.
  def test_without_the_setting_the_capture_fails
    [nil, "boot.rb"].each do |boot|
      tag = boot ? "MissingBoot" : "Missing"
      with_project(tag, source_probe: false) do |proj, _log, _tag|
        write(proj, "boot.rb", "require_relative \"lib/load_path_calc_#{tag}\"\n")
        _out, err = capture_subprocess_io do
          assert_raises(Mutineer::SmokeCheckError) do
            Mutineer::Runner.execute(config_for(proj, tag, extra: [], boot: boot))
          end
        end
        assert_includes err, "coverage skipped for test/load_path_calc_#{tag}_test.rb", boot.inspect
      end
    end
  end

  # A directory already on $LOAD_PATH (here through RUBYLIB) is not filtered
  # out: x1 still comes before x2 in the parent, the mutant forks and the
  # capture subprocess, so all of them load x1's copy.
  def test_a_directory_already_on_the_path_keeps_its_place
    with_project("Rubylib") do |proj, log, tag|
      x1 = File.join(proj, "x1")
      $LOAD_PATH.push(x1)
      aggregate = nil
      with_env("RUBYLIB" => x1) do
        aggregate, = Mutineer::Runner.execute(config_for(proj, tag, extra: %w[x1 x2]))
      end

      assert_operator aggregate.killed_count, :>, 0
      assert_equal %w[fork subprocess], lines(log).map { |l| l["kind"] }.uniq.sort
      assert_equal [File.join(x1, "shared_name.rb")], lines(log).map { |l| l["shared"] }.uniq
    end
  end

  # The daemon gets the same order from DaemonBackend.boot_config. Its boot
  # file reports the $LOAD_PATH it sees and the copy of shared_name it loads.
  def test_order_in_the_daemon
    with_project("Daemon") do |proj, _log, tag|
      seen = File.join(proj, "daemon.json")
      write(proj, "boot.rb", <<~RUBY)
        require "shared_name"
        require "json"
        File.write(#{seen.dump}, JSON.generate("path" => $LOAD_PATH,
                                               "shared" => $LOADED_FEATURES.grep(%r{/shared_name\\.rb\\z}).first))
      RUBY
      config = config_for(proj, tag, extra: %w[x1 x2 x3], boot: "boot.rb")
      boot = Mutineer::DaemonBackend.boot_config(config, [File.join(proj, "test/load_path_calc_#{tag}_test.rb")])
      lib = File.expand_path("../lib", __dir__)
      script = "require \"mutineer/daemon_server\"; Mutineer::DaemonServer.run"
      out, err, = Open3.capture3(RbConfig.ruby, "-I", lib, "-e", script,
                                 stdin_data: "#{JSON.generate(boot.merge(cmd: 'boot'))}\n#{JSON.generate(cmd: 'quit')}\n")

      assert_equal true, JSON.parse(out.lines.first)["ready"], "#{out}\n#{err}"
      reported = JSON.parse(File.read(seen))
      assert_order(reported["path"], ["test", *EXTRA].map { |d| File.join(proj, d) }, "daemon")
      assert_equal File.join(proj, "x1/shared_name.rb"), reported["shared"]
    end
  end

  # R11: a run with no load_path gives CoverageMap the same load paths as
  # before, so the coverage cache digest does not change.
  def test_no_load_path_keeps_the_coverage_map_load_paths
    coverage_was_running = Coverage.running?
    with_project("Digest", source_probe: false) do |proj, _log, tag|
      write(proj, "boot.rb", "require_relative \"lib/load_path_calc_#{tag}\"\n")
      stop = Class.new(StandardError)
      { nil => %w[lib test], "boot.rb" => %w[lib] }.each do |boot, expected|
        seen = nil
        record = lambda do |**kwargs|
          seen = kwargs[:load_paths]
          raise stop
        end
        Mutineer::CoverageMap.stub(:new, record) do
          assert_raises(stop) { Mutineer::Runner.execute(config_for(proj, tag, extra: [], boot: boot)) }
        end
        assert_equal expected, seen, "boot: #{boot.inspect}"
      end
    end
  ensure
    # The stub stops the boot run before it suspends the Coverage it started,
    # and a later boot run would then treat it as the host's.
    Coverage.suspend if !coverage_was_running && Coverage.running?
  end
end
