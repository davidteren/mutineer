# frozen_string_literal: true

require "rake/testtask"

Rake::TestTask.new(:test) do |t|
  t.libs << "lib" << "test"
  # Fixtures include *_test.rb files that are loaded into forked children by
  # the runner — they are not part of Mutineer's own suite.
  t.test_files = FileList["test/**/*_test.rb"].exclude("test/fixtures/**/*")
  t.warning = false
end

begin
  require "yard"

  YARD::Rake::YardocTask.new(:yard) do |t|
    t.stats_options = ["--list-undocumented"]
  end

  namespace :yard do
    desc "Generate YARD docs and fail unless every object (incl. private) is documented"
    task strict: :yard do
      require "open3"
      out, = Open3.capture2("yard", "stats", "--list-undoc", "--private", "--protected")
      puts out
      coverage = out[/([\d.]+)% documented/, 1]&.to_f
      abort "yard:strict could not parse coverage from `yard stats` output" if coverage.nil?
      abort "yard:strict failed: #{coverage}% documented (< 100%)" if coverage < 100.0
    end
  end
rescue LoadError
  # YARD is a development dependency; its tasks are simply unavailable without it.
end

task default: :test
