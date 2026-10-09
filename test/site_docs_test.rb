# frozen_string_literal: true

require_relative "test_helper"
require_relative "../rake/site_docs"
require_relative "../rake/docs_contract"

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

  def test_llms_txt_links_to_the_production_ready_section
    text = File.read("docs/llms.txt")
    assert_includes text, "https://github.com/davidteren/mutineer#is-it-production-ready"
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

  # Every built-in chain-link skip is named on the published page.
  def test_equivalent_skips_page_names_every_chain_link_skip
    page = File.read("docs/equivalent-skips.html")
    Mutineer::Mutators::ChainLink::SKIPPED.each do |name|
      assert_includes page, ">#{name}<", "equivalent-skips.html is missing #{name}"
    end
    assert_includes page, "endless"
  end
end
