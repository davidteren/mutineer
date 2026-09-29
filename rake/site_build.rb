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
      check_dest!(dest)
      FileUtils.rm_rf(dest)
      FileUtils.mkdir_p(dest)
      copy_docs_tree!(dest)
      YardPages.generate!(File.join(dest, "api"))
      write!(File.join(dest, "llms-full.txt"), DocsContract.llms_full_txt)
      write!(File.join(dest, "json-schema.html"), DocsContract.json_schema_html)
      write!(File.join(dest, "sitemap.xml"), MutineerSiteDocs.sitemap_xml)
    end

    # The build starts with rm_rf, so refuse a destination whose removal
    # deletes the checkout or the docs/ sources.
    #
    # @param dest [String]
    # @return [void]
    # @raise [ArgumentError] when `dest` is the checkout, one of its
    #   ancestors, or inside docs/
    def check_dest!(dest)
      target = File.expand_path(dest)
      root = File.expand_path("..", __dir__)
      docs = File.join(root, "docs")
      # File.identical? is false when stat fails, so fail here, not open.
      [root, docs].each { |dir| File.stat(dir) }
      # Compare path text, and also directories: a symlinked parent, or
      # other letter case on a case-insensitive volume, names the same one.
      same = ->(a, b) { a == b || File.identical?(a, b) }
      covers_root = path_and_parents(root).any? { |dir| same.(dir, target) }
      in_docs = path_and_parents(target).any? { |dir| same.(dir, docs) }
      raise ArgumentError, "site:build: refusing to replace #{target}" if covers_root || in_docs
    end

    private

    # `path` and each parent directory up to the filesystem root.
    #
    # @param path [String] absolute path
    # @return [Array<String>]
    def path_and_parents(path)
      dirs = [path]
      dirs << File.dirname(dirs.last) until File.dirname(dirs.last) == dirs.last
      dirs
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
