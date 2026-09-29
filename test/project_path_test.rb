# frozen_string_literal: true

require_relative "test_helper"
require "tmpdir"
require "fileutils"

# ProjectPath normalizes a source path against the project root for mutant ids
# and coverage keys (#126). It must follow the file system, not string rules.
class ProjectPathTest < Minitest::Test
  # `link/../x.rb` where link points into another directory names the physical
  # file other/x.rb, not root/x.rb: `..` must be resolved after the symlink.
  def test_dot_dot_after_a_symlink_follows_the_physical_path
    Dir.mktmpdir("mutineer-pp") do |root|
      FileUtils.mkdir_p(File.join(root, "other", "deep"))
      File.write(File.join(root, "other", "x.rb"), "")
      File.write(File.join(root, "x.rb"), "")
      File.symlink(File.join(root, "other", "deep"), File.join(root, "link"))
      assert_equal "other/x.rb", Mutineer::ProjectPath.relative("link/../x.rb", root)
    end
  end

  def test_spellings_of_one_file_normalize_to_one_path
    Dir.mktmpdir("mutineer-pp") do |root|
      FileUtils.mkdir_p(File.join(root, "lib"))
      File.write(File.join(root, "lib", "x.rb"), "")
      ["lib/x.rb", "./lib/x.rb", File.join(root, "lib", "x.rb")].each do |spelling|
        assert_equal "lib/x.rb", Mutineer::ProjectPath.relative(spelling, root), spelling
      end
    end
  end

  def test_missing_root_falls_back_to_the_expanded_path
    assert_equal File.expand_path("/no/such/root"), Mutineer::ProjectPath.root_real("/no/such/root")
  end
end
