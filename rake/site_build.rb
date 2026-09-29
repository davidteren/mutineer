# frozen_string_literal: true

require "fileutils"
require_relative "yard_pages"
require_relative "site_docs"
require_relative "docs_contract"

# Assemble the published GitHub Pages tree into one output directory: the
# hand-written docs/ files copied as-is, plus the generated ones (YARD HTML,
# llms-full.txt, json-schema.html, sitemap.xml) built straight into it. Pages
# publishes this directory as a build artifact — nothing under it is committed.
module SiteBuild
  # Output directory used when the caller gives none.
  DEFAULT_DEST = "_site"

  # docs/ entries the generators below write directly into the destination,
  # so the tree copy must skip them instead of copying a (possibly absent)
  # committed version.
  GENERATED = %w[api llms-full.txt json-schema.html sitemap.xml].freeze

  class << self
    # Build the site into `dest` (removed first, then rebuilt from scratch).
    #
    # @param dest [String, nil] output directory; defaults to
    #   `SITE_BUILD_DEST` or {DEFAULT_DEST}
    # @return [void]
    def generate!(dest = nil)
      dest ||= ENV["SITE_BUILD_DEST"] || DEFAULT_DEST
      FileUtils.rm_rf(dest)
      FileUtils.mkdir_p(dest)
      copy_docs_tree!(dest)
      YardPages.generate!(File.join(dest, "api"))
      write!(File.join(dest, "llms-full.txt"), DocsContract.llms_full_txt)
      write!(File.join(dest, "json-schema.html"), DocsContract.json_schema_html)
      write!(File.join(dest, "sitemap.xml"), MutineerSiteDocs.sitemap_xml)
    end

    private

    # Copy every tracked docs/ file except the entries this task regenerates.
    #
    # @param dest [String]
    # @return [void]
    def copy_docs_tree!(dest)
      tracked_docs_paths.each do |rel|
        next if GENERATED.any? { |g| rel == g || rel.start_with?("#{g}/") }

        target = File.join(dest, rel)
        FileUtils.mkdir_p(File.dirname(target))
        FileUtils.cp(File.join("docs", rel), target)
      end
    end

    # Git-tracked paths under docs/, relative to docs/.
    #
    # @return [Array<String>]
    def tracked_docs_paths
      `git ls-files docs`.lines.map(&:chomp).map { |p| p.delete_prefix("docs/") }
    end

    # Write + trailing newline.
    #
    # @param path [String]
    # @param contents [String]
    # @return [void]
    def write!(path, contents)
      File.write(path, contents.end_with?("\n") ? contents : "#{contents}\n")
    end
  end
end
