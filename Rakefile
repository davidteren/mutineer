# frozen_string_literal: true

require "rake/testtask"

Rake::TestTask.new(:test) do |t|
  t.libs << "lib" << "test"
  # Fixtures include *_test.rb files that are loaded into forked children by
  # the runner — they are not part of Mutineer's own suite.
  t.test_files = FileList["test/**/*_test.rb"].exclude("test/fixtures/**/*")
  t.warning = false
end

task default: :test
