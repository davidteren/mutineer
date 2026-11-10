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
# (CI's Prism 2 job pins it, #400) and skips on Prism 1.
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

    # Devin: each mutant must be killed by the test of its own method, so a
    # load failure that fails every test cannot pass for a kill.
    add = "ConstBumpCalculatorTest#test_add"
    bump = "ConstBumpCalculatorTest#test_bump"
    %w[reload redefine].each do |strategy|
      assert_equal [["ConstBumpCalculator#add", "arithmetic", "killed", [add]],
                    ["ConstBumpCalculator#bump", "comparison", "killed", [bump]],
                    ["ConstBumpCalculator#bump", "statement_removal", "killed", [bump]]],
                   run_strategy(strategy).sort, strategy
    end
  end

  # Prism 2 marks the whole `LIMIT += 1` write as the error, and Ruby still
  # loads an edit inside it, so that mutant is valid.
  def test_an_edit_inside_the_line_prism_rejects_is_still_valid
    skip "this Prism accepts a constant op-assign in a method" if Mutineer::Parser.parse_string(SOURCE).errors.empty?

    ["LIMIT -= 1", "LIMIT += 2"].each do |edit|
      refute Mutineer::Parser.invalid?(SOURCE.sub("LIMIT += 1", edit)), edit
    end
  end

  private

  # Runs Mutineer in a child Ruby (it loads the fixture's classes) with
  # `matrix`, and returns each result as [subject, operator, status, the tests
  # that killed it].
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
                                      cache_dir: #{File.join(root, "cache").inspect}, jobs: 1, matrix: true)
        agg = Mutineer::Runner.execute(config).first
        $stdout.puts JSON.generate(agg.results.map { |r|
          [r.subject.qualified_name, r.mutation.operator, r.status, Array(r.kills&.killed_by).map { |row| row[1] }]
        })
      RUBY
      out, err, status = Open3.capture3(RbConfig.ruby, "-I#{LIB}", "-e", script, chdir: root)
      assert status.success?, "#{strategy} run failed: #{err}"
      JSON.parse(out.lines.last)
    end
  end
end
