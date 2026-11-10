# frozen_string_literal: true

require_relative "test_helper"

# Rails proof for class-body macro mutants on --test-command (#397).
# The fixture app has its own bundle. ExternalBackend does not set a working
# directory, so the test enters the app before the run.
class RailsMacroTestCommandTest < Minitest::Test
  APP = File.expand_path("fixtures/rails_app", __dir__)

  def run_crate(test_file)
    config = Mutineer::Config.new(
      sources: ["app/models/crate.rb"],
      tests: [test_file],
      operators: %w[macro_removal macro_option_removal],
      test_command: "bin/rails test %{files}",
      jobs: 1,
      project_root: APP,
      cache_dir: File.join(APP, "tmp", "mutineer-macro")
    )
    aggregate, = Mutineer::Runner.execute(config)
    aggregate
  end

  def test_crate_macro_mutants_on_rails
    strong = nil
    weak = nil
    Dir.chdir(APP) do
      strong = run_crate("test/models/crate_strong_test.rb")
      weak = run_crate("test/models/crate_weak_test.rb")
    end

    assert_equal 3, strong.total, statuses(strong)
    assert_equal 3, strong.killed_count, statuses(strong)
    assert_equal 0, strong.survived_count, statuses(strong)

    assert_equal 3, weak.total, statuses(weak)
    assert_equal 0, weak.killed_count, statuses(weak)
    assert_equal 3, weak.survived_count, statuses(weak)
    assert_in_delta 0.0, weak.mutation_score, 0.001
    subjects = weak.surviving_mutants.map { |result| [result.subject.qualified_name, result.mutation.operator.to_s] }
    assert_equal [
      ["Crate.has_many(:crate_items)", "macro_option_removal"],
      ["Crate.has_many(:crate_items)", "macro_removal"],
      ["Crate.validates(:label)", "macro_removal"]
    ], subjects.sort
    option = weak.surviving_mutants.find { |result| result.mutation.operator == :macro_option_removal }
    source = File.read(File.join(APP, "app/models/crate.rb"))
    token = source.byteslice(option.mutation.start_offset...option.mutation.end_offset)
    assert_equal "dependent: :destroy", token
    assert_equal strong.total, weak.surviving_mutants.map(&:id).uniq.size

    daemon = Mutineer::Config.new(
      sources: ["app/models/crate.rb"],
      operators: ["macro_removal"],
      daemon: true,
      project_root: APP
    )
    error = assert_raises(ArgumentError) { Mutineer::Runner.execute(daemon) }
    assert_includes error.message, "--test-command"
    assert_includes error.message, "#389"
  end

  def statuses(aggregate)
    aggregate.results.map { |result| "#{result.subject&.qualified_name} #{result.mutation&.operator} #{result.status}" }.join(", ")
  end
end
