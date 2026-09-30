# frozen_string_literal: true

require "fileutils"
require "tmpdir"

require_relative "test_helper"
require_relative "../rake/site_docs"
require_relative "../rake/yard_pages"
require_relative "../rake/docs_contract"

# #92: published YARD HTML tracks the shipped gem.
#
# A real `yard doc` rebuild is slow, so it never runs in the default suite
# (this file must not call `YardPages.generate!`). `rake site:build`'s own
# `verify_api!` is what catches a broken build (missing index, stale
# VERSION, missing Jekyll markers) — see rake/site_build.rb.
class YardPagesTest < Minitest::Test
  def test_catalog_lists_the_api_root
    paths = MutineerSiteDocs::CATALOG.map(&:path)
    assert_includes paths, "/api/"
  end

  def test_site_nav_links_to_api
    %w[docs/index.html docs/agentic-coding.html docs/sample-report.html].each do |path|
      assert_includes File.read(path), 'href="api/"', "#{path} should link to api/"
    end
    assert_includes DocsContract.json_schema_html, 'href="api/"', "json-schema.html should link to api/"
  end

  def test_documentation_uri_stays_the_pages_root
    spec = File.read("mutineer.gemspec")
    assert_includes spec, '"documentation_uri" => "https://davidteren.github.io/mutineer/"'
  end

  def test_published_markers_require_root_and_api_nojekyll
    Dir.mktmpdir("yard-markers") do |dir|
      api = File.join(dir, "api")
      FileUtils.mkdir_p(api)
      FileUtils.touch(File.join(dir, ".nojekyll"))
      FileUtils.touch(File.join(api, ".nojekyll"))
      assert YardPages.published_markers?(api)
    end
  end

  def test_published_markers_false_when_the_root_nojekyll_is_missing
    Dir.mktmpdir("yard-markers-missing") do |dir|
      api = File.join(dir, "api")
      FileUtils.mkdir_p(api)
      FileUtils.touch(File.join(api, ".nojekyll"))
      # No `dir/.nojekyll` — Pages would run Jekyll and drop `_index.html`.
      refute YardPages.published_markers?(api)
    end
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

  def test_changelog_headings_keep_aliases_and_stable_release_anchors
    Dir.mktmpdir("yard-headings") do |dir|
      path = File.join(dir, "file.CHANGELOG.html")
      File.write(path, <<~HTML)
        <h2 id="release_1_4">1.4</h2><h3 id="Added">Added</h3>
        <h2 id="release_1_3">1.3</h2><h3 id="Added">Added</h3>
        <h3 id="Changed">Changed</h3>
        <h2 id="release_1_2">1.2</h2><h3 id="Changed">Changed</h3>
        <h3 id="id">id</h3>
      HTML
      original = File.read(path)
      YardPages.send(:stabilize_html!, dir)
      html = File.read(path)
      assert_includes html, 'id="Added"'
      assert_includes html, 'id="release_1_4-Added"'
      assert_includes html, 'id="release_1_3-Added"'
      assert_includes html, 'id="release_1_3-Changed"'
      assert_includes html, 'id="release_1_2-Changed"'
      assert_includes html, '<h3 id="release_1_2-id">'
      ids = html.scan(/\bid="([^"]+)"/).flatten
      assert_equal ids.uniq, ids
      YardPages.send(:stabilize_html!, dir)
      assert_equal html, File.read(path), "a second pass must preserve anchors"
      File.write(path, '<h2 id="Unreleased">Unreleased</h2><h3 id="Added">Added</h3>' + original)
      YardPages.send(:stabilize_html!, dir)
      assert_includes File.read(path), 'id="release_1_4-Added"', "new releases must not move release anchors"
      ids = File.read(path).scan(/\bid="([^"]+)"/).flatten
      assert_equal ids.uniq, ids
    end
  end
end
