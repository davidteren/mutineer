# frozen_string_literal: true

require "minitest/mock"
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

  def test_check_dest_refuses_by_path_when_file_identity_is_unknown
    File.stub(:identical?, false) do
      [ROOT, File.join(ROOT, "docs")].each do |dest|
        assert_raises(ArgumentError, dest) { SiteBuild.check_dest!(dest) }
      end
    end
  end

  def test_check_dest_accepts_a_build_directory
    assert_nil SiteBuild.check_dest!(File.join(ROOT, "_site"))
  end

  def test_check_dest_refuses_the_checkout_and_docs_through_a_symlink
    Dir.mktmpdir do |dir|
      link = File.join(dir, "checkout")
      File.symlink(ROOT, link)
      [link, File.join(link, "docs"), File.join(link, "docs/new")].each do |dest|
        assert_raises(ArgumentError, dest) { SiteBuild.check_dest!(dest) }
      end
    end
  end

  def test_check_dest_refuses_docs_in_other_letter_case
    other_case = File.join(ROOT, "DOCS")
    skip "case-sensitive filesystem" unless File.identical?(other_case, File.join(ROOT, "docs"))

    assert_raises(ArgumentError) { SiteBuild.check_dest!(other_case) }
  end

  def test_tracked_docs_paths_raises_outside_a_checkout
    Dir.mktmpdir do |dir|
      # Stop git at `dir`, even when the temp directory sits inside a checkout.
      ceiling = ENV["GIT_CEILING_DIRECTORIES"]
      ENV["GIT_CEILING_DIRECTORIES"] = File.dirname(File.realpath(dir))
      err = nil
      capture_subprocess_io do
        err = Dir.chdir(dir) { assert_raises(RuntimeError) { SiteBuild.send(:tracked_docs_paths) } }
      end
      assert_match(/git ls-files docs/, err.message)
    ensure
      ENV["GIT_CEILING_DIRECTORIES"] = ceiling
    end
  end
end
