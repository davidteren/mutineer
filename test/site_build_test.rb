# frozen_string_literal: true

require "minitest/mock"
require "tmpdir"
require "open3"
require_relative "test_helper"
require_relative "../rake/site_build"

# #153: site:build deploys only what git tracks. #162: it removes only _site.
class SiteBuildTest < Minitest::Test
  ROOT = File.expand_path("..", __dir__)

  # #162: the only directory the build removes is _site at the checkout root,
  # whatever the working directory is.
  def test_generate_removes_only_the_checkout_site_directory
    removed = []
    Dir.mktmpdir do |elsewhere|
      FileUtils.stub(:rm_rf, ->(path) { removed << path; throw :stop }) do
        catch(:stop) { Dir.chdir(elsewhere) { SiteBuild.generate! } }
      end
    end
    assert_equal [File.join(ROOT, "_site")], removed
  end

  # The removed destination argument fails, so an old caller does not look for
  # its output in a directory the build never writes.
  def test_rake_task_rejects_a_destination
    out, status = Open3.capture2e("bundle", "exec", "rake", "site:build[#{Dir.tmpdir}/x]", chdir: ROOT)
    refute status.success?
    assert_match(/takes no destination/, out)

    out, status = Open3.capture2e({ "SITE_BUILD_DEST" => "#{Dir.tmpdir}/x" }, "bundle", "exec", "rake", "site:build", chdir: ROOT)
    refute status.success?
    assert_match(/SITE_BUILD_DEST/, out)
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
