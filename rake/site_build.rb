# frozen_string_literal: true

require "fileutils"
require_relative "yard_pages"
require_relative "site_docs"
require_relative "docs_contract"
require_relative "../lib/mutineer/version"

# Assemble the published GitHub Pages tree into one output directory: the
# hand-written docs/ files copied as-is, plus the generated ones (YARD HTML,
# llms-full.txt, json-schema.html, sitemap.xml) built straight into it. Pages
# publishes this directory as a build artifact — nothing under it is committed.
module SiteBuild
  # The one directory the build removes and rewrites. It is a constant, not a
  # parameter, so no argument can aim the removal at `lib/` or `.git`.
  DEST = File.expand_path("../_site", __dir__)

  # The checkout root. The build reads docs/ and runs git and YARD from here,
  # so a caller in another directory still builds this checkout's site.
  ROOT = File.expand_path("..", __dir__)

  # docs/ entries the generators below write directly into the destination,
  # so the tree copy must skip them instead of copying a (possibly absent)
  # committed version.
  GENERATED = %w[api llms-full.txt json-schema.html sitemap.xml].freeze

  class << self
    # Build the site into {DEST} (removed first, then rebuilt from scratch),
    # from the checkout root whatever the working directory is.
    #
    # @return [void]
    def generate!
      Dir.chdir(ROOT) { build! }
    end

    private

    # The build itself; {generate!} runs it from {ROOT}.
    #
    # @return [void]
    def build!
      FileUtils.rm_rf(DEST)
      FileUtils.mkdir_p(DEST)
      copy_docs_tree!(DEST)
      api = File.join(DEST, "api")
      YardPages.generate!(api)
      verify_api!(api)
      write!(File.join(DEST, "llms-full.txt"), DocsContract.llms_full_txt)
      write!(File.join(DEST, "json-schema.html"), DocsContract.json_schema_html)
      write!(File.join(DEST, "sitemap.xml"), MutineerSiteDocs.sitemap_xml)
    end

    # Fail loudly if the YARD build did not produce a usable `api/`. CI's
    # site job and the release workflow run `site:build`, so this fails them
    # when the build names the wrong VERSION or lacks its Jekyll opt-out
    # markers.
    #
    # @param api [String]
    # @return [void]
    def verify_api!(api)
      index = File.join(api, "index.html")
      raise "site:build: #{index} is missing" unless File.file?(index)

      stamped = [File.join(api, "_index.html"), File.join(api, "Mutineer.html")]
        .select { |p| File.file?(p) }
        .any? { |p| File.read(p).include?(Mutineer::VERSION) }
      raise "site:build: api/_index.html and api/Mutineer.html do not mention " \
            "Mutineer::VERSION (#{Mutineer::VERSION})" unless stamped

      unless YardPages.published_markers?(api)
        raise "site:build: #{api} is missing the .nojekyll markers"
      end
    end

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

    # Git-tracked paths under docs/, relative to docs/. Raises when git
    # fails or finds nothing, so a build outside a checkout does not deploy
    # a site without its pages.
    #
    # @return [Array<String>]
    def tracked_docs_paths
      out = `git ls-files docs`
      raise "site:build: `git ls-files docs` failed" unless $?.success?

      paths = out.lines.map(&:chomp).map { |p| p.delete_prefix("docs/") }
      raise "site:build: git tracks no files under docs/" if paths.empty?

      paths
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
