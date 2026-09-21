# frozen_string_literal: true

require "fileutils"
require "tmpdir"

require_relative "test_helper"
require_relative "../rake/site_docs"
require_relative "../rake/yard_pages"
require_relative "../lib/mutineer/version"

# #92: published YARD HTML tracks the shipped gem.
#
# Freshness against a live `yard doc` rebuild is `rake yard:pages:check`
# (Linux CI + release), not this suite — a rebuild is slow and macOS YARD
# HTML can still differ after timestamp/Ruby-patch normalization.
class YardPagesTest < Minitest::Test
  def test_catalog_lists_the_api_root
    paths = MutineerSiteDocs::CATALOG.map(&:path)
    assert_includes paths, "/api/"
  end

  def test_api_index_exists_and_names_this_version
    assert_includes File.read("docs/api/index.html"), "Mutineer"
    listed = File.read("docs/api/_index.html") + File.read("docs/api/Mutineer.html")
    assert_includes listed, Mutineer::VERSION
  end

  def test_site_nav_links_to_api
    %w[docs/index.html docs/agentic-coding.html docs/json-schema.html docs/sample-report.html].each do |path|
      assert_includes File.read(path), 'href="api/"', "#{path} should link to api/"
    end
  end

  def test_documentation_uri_stays_the_pages_root
    spec = File.read("mutineer.gemspec")
    assert_includes spec, '"documentation_uri" => "https://davidteren.github.io/mutineer/"'
  end

  def test_published_markers_require_root_and_api_nojekyll
    assert YardPages.published_markers?
  end

  def test_equivalent_ignores_stamp_ruby_patch_and_yard_version
    left = <<~HTML
      <title>Documentation by YARD 0.9.45</title>
      Generated on Mon Sep 21 07:52:23 2026 by
      <a href="https://yardoc.org">yard</a>
      0.9.45 (ruby-3.4.10).
    HTML
    right = <<~HTML
      <title>Documentation by YARD 0.9.46</title>
      Generated on Tue Sep 22 01:02:03 2026 by
      <a href="https://yardoc.org">yard</a>
      0.9.46 (ruby-3.4.7).
    HTML

    Dir.mktmpdir("yard-eq") do |dir|
      a = File.join(dir, "a")
      b = File.join(dir, "b")
      FileUtils.mkdir_p([a, b])
      File.write(File.join(a, "index.html"), left)
      File.write(File.join(b, "index.html"), right)
      assert YardPages.equivalent?(a, b)
    end
  end

  def test_equivalent_rejects_content_or_file_list_drift
    Dir.mktmpdir("yard-neq") do |dir|
      a = File.join(dir, "a")
      b = File.join(dir, "b")
      FileUtils.mkdir_p([a, b])
      File.write(File.join(a, "index.html"), "alpha")
      File.write(File.join(b, "index.html"), "beta")
      refute YardPages.equivalent?(a, b)

      File.write(File.join(b, "index.html"), "alpha")
      File.write(File.join(b, "extra.html"), "x")
      refute YardPages.equivalent?(a, b)
    end
  end
end
