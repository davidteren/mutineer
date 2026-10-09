# frozen_string_literal: true

require_relative "test_helper"
require_relative "../rake/site_docs"
require_relative "../rake/docs_contract"
require "yaml"

# #91: sitemap.xml and llms.txt stay generated from one catalog.
#
# sitemap.xml is a Pages build artifact (`rake site:build`), not a committed
# file — tests below render it fresh instead of reading docs/sitemap.xml.
class SiteDocsTest < Minitest::Test
  ALTERNATE = 'rel="alternate" type="text/markdown"'

  def test_catalog_covers_the_issue_91_urls
    paths = MutineerSiteDocs::CATALOG.map(&:path)
    %w[
      /
      /index.md
      /agentic-coding.html
      /agentic-coding.md
      /json-schema.html
      /json-schema.md
      /sample-report.html
      /llms.txt
      /llms-full.txt
      /skill.md
      /agents.txt
    ].each { |path| assert_includes paths, path }
  end

  def test_committed_llms_txt_matches_a_fresh_generate
    source = File.read("docs/llms.txt")
    assert_equal MutineerSiteDocs.llms_txt(source), source
  end

  def test_llms_txt_lists_skill_md_under_optional
    text = File.read("docs/llms.txt")
    optional = text.split("## Optional", 2)[1]
    refute_nil optional, "docs/llms.txt needs an Optional section"
    assert_includes optional, MutineerSiteDocs.loc("/skill.md")
  end

  def test_sitemap_lists_every_catalog_loc
    xml = MutineerSiteDocs.sitemap_xml
    MutineerSiteDocs::CATALOG.each do |entry|
      assert_includes xml, "<loc>#{MutineerSiteDocs.loc(entry.path)}</loc>"
    end
  end

  def test_html_pages_with_markdown_twins_advertise_alternate
    MutineerSiteDocs::HTML_MARKDOWN_TWINS.each do |html, twin|
      # json-schema.html is a Pages build artifact — render it instead of
      # reading a committed copy.
      source = html == "docs/json-schema.html" ? DocsContract.json_schema_html : File.read(html)
      assert_includes source, ALTERNATE, "#{html} needs #{ALTERNATE}"
      assert_includes source, MutineerSiteDocs.loc("/#{twin}")
    end
  end

  def test_index_md_exists_and_covers_cli_essentials
    text = File.read("docs/index.md")
    assert_match(/gem install mutineer/, text)
    assert_match(/mutineer run/, text)
    assert_match(/--threshold/, text)
    assert_includes text, MutineerSiteDocs.loc("/agentic-coding.md")
    assert_includes text, MutineerSiteDocs.loc("/json-schema.md")
  end

  def test_stale_files_is_empty_at_head
    assert_empty MutineerSiteDocs.stale_files
  end

  # The Rails guide is in the primary nav, and every YAML recipe parses.
  def test_rails_guide_is_linked_and_its_yaml_parses
    %w[docs/index.html docs/agentic-coding.html docs/sample-report.html docs/rails.html].each do |path|
      assert_includes File.read(path), 'href="rails.html"', path
    end
    assert_includes File.read("rake/docs_contract.rb"), 'href="rails.html"'
    page = File.read("docs/rails.md")
    assert_includes page, "One model locally"
    assert_includes page, "Report-only in CI"
    assert_includes page, "--since origin/main"
    assert_includes page, "--baseline"
    assert_includes page, "--threshold"
    assert_includes page, "GitLab CI"
    blocks = page.scan(/```yaml\n(.*?)```/m).flatten
    assert_equal 2, blocks.size
    blocks.each do |body|
      loaded = YAML.safe_load(body)
      assert_kind_of Hash, loaded
    end
  end
end
