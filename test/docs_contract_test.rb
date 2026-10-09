# frozen_string_literal: true

require_relative "test_helper"
require_relative "../rake/docs_contract"
require_relative "../rake/site_docs"

# #82: one contract file, generated copies, CI fails when they drift.
#
# docs/json-schema.html and docs/llms-full.txt are Pages build artifacts
# (`rake site:build`), not committed files — tests read those two from a
# fresh render (`DocsContract.json_schema_html` / `.llms_full_txt`) instead
# of disk.
class DocsContractTest < Minitest::Test
  # Committed Markdown/README surfaces, read straight from disk.
  DISK_SURFACES = %w[
    README.md
    STABILITY.md
    docs/json-schema.md
    docs/agentic-coding.md
  ].freeze

  # Build-artifact surfaces, rendered fresh instead of read from disk.
  RENDERED_SURFACES = {
    "docs/json-schema.html" => -> { DocsContract.json_schema_html },
    "docs/llms-full.txt" => -> { DocsContract.llms_full_txt }
  }.freeze

  def test_every_contract_surface_carries_the_same_exit_codes
    surfaces = DISK_SURFACES.to_h { |path| [path, -> { File.read(path) }] }.merge(RENDERED_SURFACES)
    surfaces.each do |path, render|
      text = render.call
      %w[0 1 2 3].each do |code|
        assert_includes text, code
        assert_includes plain(text), plain(DocsContract.meaning_plain(code)),
          "#{path} is missing exit-code #{code} meaning"
      end
    end
  end

  def test_llms_full_concatenates_the_readme_agentic_and_schema_sources
    text = DocsContract.llms_full_txt
    assert_includes text, "# README"
    assert_includes text, File.read("docs/agentic-coding.md").lines.first.chomp
    assert_includes text, File.read("docs/json-schema.md").lines.first.chomp
  end

  def test_json_schema_html_keeps_playwright_summary_region_and_markdown_alternate
    html = DocsContract.json_schema_html
    assert_includes html, 'aria-label="Summary fields"'
    assert_includes html, 'rel="alternate" type="text/markdown"'
    assert_includes html, "https://davidteren.github.io/mutineer/json-schema.md"
  end

  def test_action_yml_descriptions_come_from_the_contract_file
    yaml = File.read("action.yml")
    assert_includes yaml, DocsContract.contract.fetch("threshold_action")
    assert_includes yaml, DocsContract.contract.fetch("exit_code_action")
  end

  def test_docs_check_is_clean
    assert_empty MutineerSiteDocs.stale_files
  end

  def test_apply_threshold_row_rewrites_an_edited_meaning_cell
    edited = File.read("README.md").sub(
      "| `--threshold FLOAT` | Exit 1 when",
      "| `--threshold FLOAT` | garbled when"
    )
    refute_includes edited, DocsContract.contract.fetch("threshold_readme")
    restored = DocsContract.send(:apply_threshold_row, edited)
    assert_includes restored, "| `--threshold FLOAT` | #{DocsContract.contract.fetch('threshold_readme')} |"
  end

  def test_apply_action_rewrites_edited_descriptions_by_yaml_key
    edited = File.read("action.yml")
      .sub("Fail (exit 1)", "Fails with exit 1")
      .sub("The exit code returned by mutineer", "Exit status from mutineer")
    refute_includes edited, DocsContract.contract.fetch("threshold_action")
    restored = DocsContract.send(:apply_action, edited)
    assert_includes restored, DocsContract.contract.fetch("threshold_action")
    assert_includes restored, DocsContract.contract.fetch("exit_code_action")
  end

  def test_apply_threshold_row_raises_when_the_flag_row_is_missing
    error = assert_raises(RuntimeError) { DocsContract.send(:apply_threshold_row, "| `--jobs N` | Parallel |\n") }
    assert_match(/target missing/, error.message)
  end

  def test_apply_action_raises_when_the_yaml_keys_are_missing
    error = assert_raises(RuntimeError) { DocsContract.send(:apply_action, "name: Mutineer\n") }
    assert_match(/target missing/, error.message)
  end

  def test_json_schema_page_and_source_name_the_reporter_schema_version
    version = Mutineer::Reporter::SCHEMA_VERSION
    assert_equal version, DocsContract.schema_version(File.read("docs/json-schema.md"))
    assert_includes DocsContract.json_schema_html, "schema_version #{version}</span>"
  end

  # The support matrix is one marked block. A missing block or a missing
  # database row fails this test.
  def test_readme_support_matrix_names_each_database
    readme = File.read("README.md")
    assert_equal "## Is it production-ready?", readme[/^## .+$/]
    block = readme[/<!-- contract:support-matrix -->\n(.*?)<!-- \/contract:support-matrix -->/m]
    flunk("README is missing the support-matrix contract block") unless block
    ["SQLite file", "PostgreSQL", "MySQL", "SQLite in memory", "more than one database"].each do |name|
      assert_includes block, name, "support matrix is missing #{name}"
    end
    assert_operator block.scan("not supported").length, :>=, 2,
      "several databases must say not supported"
  end

  def test_run_errors_exit_three
    assert_equal [3], Mutineer::CLI::RUN_EXIT.values.uniq
  end

  def test_stability_lists_every_readme_exit_code
    block = File.read("README.md")[/<!-- contract:exit-codes -->.*?<!-- \/contract:exit-codes -->/m]
    codes = block.scan(/^\| `(\d+)` /).flatten
    refute_empty codes
    stability = File.read("STABILITY.md")
    codes.each { |code| assert_includes stability, "`#{code}`", "STABILITY.md is missing exit code #{code}" }
  end

  def test_json_schema_links_to_the_stability_contract
    html = DocsContract.json_schema_html
    assert_includes html, "https://github.com/davidteren/mutineer/blob/main/STABILITY.md"
    refute_includes html, "STABILITY.html"
  end

  def test_json_schema_html_carries_markdown_source_content
    md = File.read("docs/json-schema.md")
    html = DocsContract.json_schema_html
    assert_includes html, 'id="exit-codes"'
    assert_includes html, 'aria-label="Exit codes"'
    assert_includes html, "schema_version"
    assert_includes plain(html), plain(DocsContract.meaning_plain("0"))
    md.scan(/^\#{2,3}\s+(.+)$/).flatten.each do |title|
      id = DocsContract::HEADING_IDS[title]
      assert id, "json-schema.md heading #{title.inspect} needs a HEADING_IDS entry"
      assert_includes html, %(id="#{id}")
    end
  end

  private

  # Strip markup so HTML and Markdown meanings compare.
  #
  # @param text [String]
  # @return [String]
  def plain(text)
    text.gsub(/<[^>]+>/, "").gsub(/[`*]/, "").gsub(/\s+/, " ").gsub(/ +([,.;:])/, '\1').strip
  end
end
