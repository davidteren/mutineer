# frozen_string_literal: true

require "tmpdir"
require_relative "test_helper"
require_relative "../rake/site_build"

# #153: site:build removes its destination first, and deploys only what git tracks.
class SiteBuildTest < Minitest::Test
  ROOT = File.expand_path("..", __dir__)

  def test_check_dest_refuses_the_checkout_its_ancestors_and_docs
    [ROOT, File.dirname(ROOT), "/", File.join(ROOT, "docs"), File.join(ROOT, "docs/assets")].each do |dest|
      assert_raises(ArgumentError, dest) { SiteBuild.check_dest!(dest) }
    end
  end

  def test_check_dest_accepts_a_build_directory
    [File.join(ROOT, "_site"), Dir.tmpdir].each do |dest|
      assert_nil SiteBuild.check_dest!(dest)
    end
  end

  def test_tracked_docs_paths_raises_outside_a_checkout
    Dir.mktmpdir do |dir|
      err = Dir.chdir(dir) { assert_raises(RuntimeError) { SiteBuild.send(:tracked_docs_paths) } }
      assert_match(/git ls-files docs/, err.message)
    end
  end
end
