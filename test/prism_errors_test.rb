# frozen_string_literal: true

require_relative "test_helper"
require "fileutils"
require "open3"
require "json"
require "rbconfig"
require "tmpdir"

# #392: Prism 2 reports `LIMIT += 1` inside a method as a dynamic constant
# assignment (as Ruby's parse.y does), but Ruby 3.4 and 4.0 load it with their
# Prism 1. A mutant elsewhere in that file, and one in the same method (the
# redefine snippet holds that line too), must still run and get a verdict, on
# both strategies. The test runs where the loaded Prism reports the error
# (CI's Minitest 6 job loads Prism 2) and skips on Prism 1.
class PrismErrorsTest < Minitest::Test
  LIB = File.expand_path("../lib", __dir__)

  SOURCE = <<~RUBY
    class ConstBumpCalculator
      LIMIT = 1
      def bump(n)
        LIMIT += 1
        n > 10
      end

      def add(a, b)
        a + b
      end
    end
  RUBY

  TEST = <<~RUBY
    require "minitest/autorun"
    require_relative "../lib/const_bump_calculator"
    class ConstBumpCalculatorTest < Minitest::Test
      def test_add
        assert_equal 5, ConstBumpCalculator.new.add(2, 3)
      end

      def test_bump
        before = ConstBumpCalculator::LIMIT
        assert ConstBumpCalculator.new.bump(11)
        refute ConstBumpCalculator.new.bump(10)
        assert_equal before + 2, ConstBumpCalculator::LIMIT
      end
    end
  RUBY

  def test_an_error_ruby_still_loads_does_not_skip_the_files_other_mutants
    skip "this Prism accepts a constant op-assign in a method" if Mutineer::Parser.parse_string(SOURCE).errors.empty?

    %w[reload redefine].each do |strategy|
      results = run_strategy(strategy).sort
      assert_equal [["ConstBumpCalculator#add", "killed"], ["ConstBumpCalculator#bump", "killed"],
                    ["ConstBumpCalculator#bump", "killed"]], results, strategy
    end
  end

  private

  # Runs Mutineer in a child Ruby (it loads the fixture's classes) and returns
  # each result as [subject, status].
  def run_strategy(strategy)
    Dir.mktmpdir("mutineer-prism-errors") do |root|
      FileUtils.mkdir_p(File.join(root, "lib"))
      FileUtils.mkdir_p(File.join(root, "test"))
      File.write(File.join(root, "lib/const_bump_calculator.rb"), SOURCE)
      File.write(File.join(root, "test/const_bump_calculator_test.rb"), TEST)
      script = <<~RUBY
        require "mutineer"
        require "json"
        config = Mutineer::Config.new(sources: ["lib/const_bump_calculator.rb"],
                                      tests: ["test/const_bump_calculator_test.rb"],
                                      strategy: #{strategy.inspect}, project_root: #{root.inspect},
                                      cache_dir: #{File.join(root, "cache").inspect}, jobs: 1)
        agg = Mutineer::Runner.execute(config).first
        $stdout.puts JSON.generate(agg.results.map { |r| [r.subject.qualified_name, r.status] })
      RUBY
      out, err, status = Open3.capture3(RbConfig.ruby, "-I#{LIB}", "-e", script, chdir: root)
      assert status.success?, "#{strategy} run failed: #{err}"
      JSON.parse(out.lines.last)
    end
  end
end
