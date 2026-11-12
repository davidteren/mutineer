# frozen_string_literal: true

require_relative "test_helper"
require "tmpdir"
require "fileutils"
require "rbconfig"

# #282: the clean check and the mutant runs read one seed. The assertions
# are the seed and the class order, not an exit code.
class SeedContractTest < Minitest::Test
  LIB = File.expand_path("../lib", __dir__)
  PINNED = Mutineer::RunSeed::PINNED_SEED.to_s

  def setup
    @saved = %w[SEED SPEC_OPTS MUTINEER_SEED_LOG].to_h { |name| [name, ENV[name]] }
  end

  def teardown
    @saved.each { |name, value| value.nil? ? ENV.delete(name) : ENV[name] = value }
  end

  # Capture, the subprocess clean check and the in-process mutant run.
  def test_the_same_minitest_seed_reaches_the_clean_run_and_the_mutant_runs
    ENV.delete("SEED")
    assert_equal [PINNED, PINNED, PINNED], minitest_seeds
    ENV["SEED"] = "4242"
    assert_equal %w[4242 4242 4242], minitest_seeds
  end

  # The generated spec helper sets a random order and only reads the seed.
  # That read must not count as choosing one.
  def test_the_same_rspec_seed_reaches_the_clean_run_and_the_mutant_runs
    ENV.delete("SPEC_OPTS")
    assert_equal [PINNED, PINNED, PINNED], rspec_seeds(random_order: true)
    ENV["SPEC_OPTS"] = "--seed 4242"
    assert_equal %w[4242 4242 4242], rspec_seeds(random_order: true)
  end

  def test_an_rspec_helper_that_sets_the_seed_reaches_both_runs
    ENV.delete("SPEC_OPTS")
    assert_equal %w[77 77 77], rspec_seeds(assign_seed: 77)
  end

  # A --require file sets the seed before the spec loads. The watcher has to
  # be on already, or pin! replaces 77 with the pinned seed.
  def test_a_preloaded_rspec_seed_reaches_the_clean_run
    ENV.delete("SPEC_OPTS")
    assert_equal [77, 77], preloaded_rspec_seeds("RSpec.configure { |config| config.seed = 77 }")
  end

  # A preload that only turns random order on has not chosen a seed.
  def test_a_preload_that_only_sets_random_order_keeps_the_pinned_seed
    ENV.delete("SPEC_OPTS")
    body = "RSpec.configure { |config| config.order = :random; Kernel.srand config.seed }"
    assert_equal [PINNED.to_i, PINNED.to_i], preloaded_rspec_seeds(body)
  end

  # Boot and --require run in the parent. The fork inherits the seed they set.
  def test_a_fork_keeps_a_seed_set_before_it_starts
    ENV.delete("SPEC_OPTS")
    Dir.mktmpdir("mutineer-fork-seed") do |dir|
      log = File.join(dir, "seed")
      req = File.join(dir, "spec_seed.rb")
      spec = File.join(dir, "subject_spec.rb")
      File.write(req, "require \"rspec/core\"\nRSpec.configure { |config| config.seed = 77 }\n")
      File.write(spec, <<~RUBY)
        RSpec.describe "seed" do
          it "records the seed" do
            File.write(#{log.inspect}, RSpec.configuration.seed.to_s)
          end
        end
      RUBY
      config = Mutineer::Config.new(sources: [req], tests: [spec], framework: "rspec",
                                    project_root: dir, require_paths: [req])
      Mutineer::Runner.send(:prepare_rspec_seed!, config)
      load req
      pid = fork do
        Mutineer::ChildStdout.silence
        exit Mutineer::TestRunners::RSpec.run([spec])
      end
      Process.wait(pid)
      assert_equal "77", File.read(log)
    end
  ensure
    ::RSpec.reset if defined?(::RSpec.reset)
  end

  # Minitest re-seeds method order from the seed inside each class, so another
  # file does not reshuffle it.
  def test_minitest_method_order_inside_a_class_does_not_depend_on_the_other_files
    ENV.delete("SEED")
    Dir.mktmpdir("mutineer-method-order") do |dir|
      log = File.join(dir, "order")
      ENV["MUTINEER_SEED_LOG"] = log
      file_a = write_minitest_methods(dir, "a")
      file_b = write_minitest_classes(dir, "b", %w[B1])
      alone = minitest_order([file_a], log)
      both = minitest_order([file_a, file_b], log, stop: true)
      assert_equal "test_dtest_ctest_atest_b", alone
      assert_equal "#{alone}B1", both
    end
  end

  # RSpec's random order sorts each group by a hash of the seed and its id, so
  # another spec does not change the order inside the first.
  def test_rspec_order_inside_a_file_does_not_depend_on_the_other_files
    ENV.delete("SPEC_OPTS")
    Dir.mktmpdir("mutineer-rspec-groups") do |dir|
      log = File.join(dir, "order")
      ENV["MUTINEER_SEED_LOG"] = log
      file_a = write_rspec_groups(dir, "a")
      file_b = write_rspec_groups(dir, "b", groups: %w[B1])
      alone = rspec_order_of([file_a], log)
      both = rspec_order_of([file_a, file_b], log)
      assert_equal alone, both.gsub("B1one", "").gsub("B1two", "")
    end
  end

  def test_the_named_rspec_seed_is_the_last_option_in_spec_opts
    ENV["SPEC_OPTS"] = "--order rand:7 --seed 8"
    assert_equal "8", Mutineer::TestRunners::RSpecSeed.advertised_seed
    ENV["SPEC_OPTS"] = "--seed 8 --order random:7"
    assert_equal "7", Mutineer::TestRunners::RSpecSeed.advertised_seed
  end

  # Forcing a seed must not turn a defined order into a random one.
  def test_a_defined_rspec_order_stays_defined_on_the_clean_run_and_the_mutant_run
    ENV.delete("SPEC_OPTS")
    assert_equal %w[abcd abcd abcd], rspec_orders
  end

  # Seed 1 shuffles three classes in a file one way, and a different way once
  # a second file joins the same list. The per-file shuffle does not.
  def test_minitest_class_order_inside_a_file_does_not_depend_on_the_other_files
    ENV.delete("SEED")
    Dir.mktmpdir("mutineer-class-order") do |dir|
      log = File.join(dir, "order")
      ENV["MUTINEER_SEED_LOG"] = log
      source = File.join(dir, "subject.rb")
      File.write(source, "class SeedContractSubject\n  def value = 1\nend\n")
      file_a = write_minitest_classes(dir, "a", %w[A1 A2 A3])
      file_b = write_minitest_classes(dir, "b", %w[B1])
      alone = minitest_order([file_a], log)
      both = minitest_order([file_a, file_b], log, stop: true)
      clean = minitest_clean_order(dir, source, [file_a, file_b], log)
      assert_equal "A1A3A2", alone
      assert_equal "A1A3A2B1", both
      assert_equal both, clean
      assert_equal alone, both.delete_suffix("B1")
    end
  end

  private

  def minitest_seeds
    Dir.mktmpdir("mutineer-seed") do |dir|
      log = File.join(dir, "seed")
      ENV["MUTINEER_SEED_LOG"] = log
      source = File.join(dir, "subject.rb")
      test = File.join(dir, "subject_test.rb")
      File.write(source, "class SeedContractSubject\n  def value = 1\nend\n")
      File.write(test, <<~RUBY)
        require "minitest"
        class SeedContractSeedTest < Minitest::Test
          def test_records_the_seed
            File.write(ENV.fetch("MUTINEER_SEED_LOG"), Minitest.seed.to_s)
          end
        end
      RUBY
      map = Mutineer::CoverageMap.new(source_paths: [source], test_paths: [test],
                                      cache_dir: File.join(dir, "cache"), project_root: dir)
      seeds = []
      capture_subprocess_io do
        File.write(log, "")
        map.send(:capture, test)
        seeds << File.read(log)
        File.write(log, "")
        map.send(:subprocess_clean_pass?, [test])
        seeds << File.read(log)
      end
      File.write(log, "")
      run_minitest([test], stop: true)
      seeds << File.read(log)
      seeds
    end
  end

  def rspec_seeds(random_order: false, assign_seed: nil)
    Dir.mktmpdir("mutineer-rspec-seed") do |dir|
      log = File.join(dir, "seed")
      ENV["MUTINEER_SEED_LOG"] = log
      source = File.join(dir, "subject.rb")
      spec = File.join(dir, "subject_spec.rb")
      File.write(source, "class SeedContractSubject\n  def value = 1\nend\n")
      File.write(spec, rspec_seed_spec(random_order:, assign_seed:))
      map = Mutineer::CoverageMap.new(source_paths: [source], test_paths: [spec],
                                      cache_dir: File.join(dir, "cache"), project_root: dir,
                                      framework: "rspec")
      seeds = []
      capture_subprocess_io do
        File.write(log, "")
        map.send(:capture, spec)
        seeds << File.read(log)
        File.write(log, "")
        map.send(:subprocess_clean_pass?, [spec])
        seeds << File.read(log)
      end
      File.write(log, "")
      run_rspec([spec], stop: true)
      seeds << File.read(log)
      seeds
    end
  end

  def rspec_seed_spec(random_order:, assign_seed:)
    config = []
    config << "config.order = :random" if random_order
    config << "config.seed = #{assign_seed}" if assign_seed
    config << "Kernel.srand config.seed" if random_order
    <<~RUBY
      RSpec.configure { |config| #{config.join("; ")} }
      RSpec.describe "seed" do
        it "records the seed" do
          File.write(ENV.fetch("MUTINEER_SEED_LOG"), RSpec.configuration.seed.to_s)
        end
      end
    RUBY
  end

  def preloaded_rspec_seeds(configure)
    Dir.mktmpdir("mutineer-preload-seed") do |dir|
      log = File.join(dir, "seed")
      ENV["MUTINEER_SEED_LOG"] = log
      source = File.join(dir, "subject.rb")
      req = File.join(dir, "spec_seed.rb")
      spec = File.join(dir, "subject_spec.rb")
      File.write(source, "class SeedContractSubject\n  def value = 1\nend\n")
      File.write(req, "require \"rspec/core\"\n#{configure}\n")
      File.write(spec, <<~RUBY)
        RSpec.describe "seed" do
          it "records the seed" do
            File.write(ENV.fetch("MUTINEER_SEED_LOG"), RSpec.configuration.seed.to_s)
          end
        end
      RUBY
      map = Mutineer::CoverageMap.new(source_paths: [source], test_paths: [spec], require_paths: [req],
                                      cache_dir: File.join(dir, "cache"), project_root: dir,
                                      framework: "rspec")
      seeds = []
      capture_subprocess_io do
        File.write(log, "")
        map.send(:capture, spec)
        seeds << File.read(log).to_i
        File.write(log, "")
        map.send(:subprocess_clean_pass?, [spec])
        seeds << File.read(log).to_i
      end
      seeds
    end
  end

  def write_minitest_methods(dir, letter)
    path = File.join(dir, "#{letter}_methods_test.rb")
    methods = %w[test_a test_b test_c test_d].map do |name|
      "  def #{name}; File.open(ENV.fetch(\"MUTINEER_SEED_LOG\"), \"a\") { |file| file.write(#{name.inspect}) }; end\n"
    end.join
    File.write(path, "require \"minitest\"\nclass Order#{letter}MethodsTest < Minitest::Test\n#{methods}end\n")
    path
  end

  def write_rspec_groups(dir, letter, groups: %w[A1 A2])
    path = File.join(dir, "#{letter}_groups_spec.rb")
    body = groups.map do |name|
      <<~RUBY
        RSpec.describe #{name.inspect} do
          it("one") { File.open(ENV.fetch("MUTINEER_SEED_LOG"), "a") { |file| file.write(#{name.inspect} + "one") } }
          it("two") { File.open(ENV.fetch("MUTINEER_SEED_LOG"), "a") { |file| file.write(#{name.inspect} + "two") } }
        end
      RUBY
    end.join
    File.write(path, "RSpec.configure { |config| config.order = :random; Kernel.srand config.seed }\n#{body}")
    path
  end

  def rspec_order_of(files, log)
    File.write(log, "")
    run_rspec(files, stop: false)
    File.read(log)
  end

  def rspec_orders
    Dir.mktmpdir("mutineer-rspec-order") do |dir|
      log = File.join(dir, "order")
      ENV["MUTINEER_SEED_LOG"] = log
      source = File.join(dir, "subject.rb")
      spec = File.join(dir, "subject_spec.rb")
      File.write(source, "class SeedContractSubject\n  def value = 1\nend\n")
      File.write(spec, <<~RUBY)
        RSpec.describe "defined" do
          %w[a b c d].each do |letter|
            it(letter) { File.open(ENV.fetch("MUTINEER_SEED_LOG"), "a") { |file| file.write(letter) } }
          end
        end
      RUBY
      map = Mutineer::CoverageMap.new(source_paths: [source], test_paths: [spec],
                                      cache_dir: File.join(dir, "cache"), project_root: dir,
                                      framework: "rspec")
      orders = []
      capture_subprocess_io do
        File.write(log, "")
        map.send(:capture, spec)
        orders << File.read(log)
        File.write(log, "")
        map.send(:subprocess_clean_pass?, [spec])
        orders << File.read(log)
      end
      File.write(log, "")
      run_rspec([spec], stop: true)
      orders << File.read(log)
      orders
    end
  end

  def write_minitest_classes(dir, letter, names)
    path = File.join(dir, "#{letter}_order_test.rb")
    body = names.map do |name|
      <<~RUBY
        class Order#{letter}#{name}Test < Minitest::Test
          def test_mark
            File.open(ENV.fetch("MUTINEER_SEED_LOG"), "a") { |file| file.write(#{name.inspect}) }
          end
        end
      RUBY
    end.join
    File.write(path, "require \"minitest\"\n#{body}")
    path
  end

  def minitest_order(files, log, stop: false)
    File.write(log, "")
    run_minitest(files, stop:)
    File.read(log)
  end

  def minitest_clean_order(dir, source, files, log)
    File.write(log, "")
    map = Mutineer::CoverageMap.new(source_paths: [source], test_paths: files,
                                    cache_dir: File.join(dir, "cache"), project_root: dir)
    capture_subprocess_io { map.send(:subprocess_clean_pass?, files) }
    File.read(log)
  end

  def run_minitest(files, stop:)
    script = "require 'mutineer'; Mutineer::ChildStdout.silence; " \
             "exit Mutineer::TestRunners::Minitest.run(#{files.inspect}, stop_at_first_failure: #{stop})"
    system(RbConfig.ruby, "-I#{LIB}", "-e", script, out: File::NULL, err: File::NULL)
  end

  def run_rspec(files, stop:)
    script = "require 'mutineer'; Mutineer::ChildStdout.silence; " \
             "exit Mutineer::TestRunners::RSpec.run(#{files.inspect}, stop_at_first_failure: #{stop})"
    system(RbConfig.ruby, "-I#{LIB}", "-e", script, out: File::NULL, err: File::NULL)
  end
end
