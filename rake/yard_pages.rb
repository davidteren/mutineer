# frozen_string_literal: true

require "fileutils"

# Generate YARD HTML for the Pages `/api/` URL. `SiteBuild.generate!` calls
# this with `<dest>/api` (see rake/site_build.rb).
module YardPages
  class << self
    # Generate YARD HTML into `output_dir` and disable Jekyll on the site.
    #
    # @param output_dir [String] where the API HTML lands (the `/api/` URL)
    # @return [void]
    def generate!(output_dir)
      FileUtils.rm_rf(output_dir)
      ok = system("bundle", "exec", "yard", "doc", "--output-dir", output_dir)
      raise "yard doc failed" unless ok

      FileUtils.touch(File.join(output_dir, ".nojekyll"))
      FileUtils.touch(File.join(File.dirname(output_dir), ".nojekyll"))
      stabilize_html!(output_dir)
    end

    # True when the site-root Jekyll opt-out and `output_dir/.nojekyll` exist.
    #
    # Without the root marker, Pages runs Jekyll and omits `_index.html`.
    #
    # @param output_dir [String]
    # @return [Boolean]
    def published_markers?(output_dir)
      File.directory?(output_dir) &&
        File.file?(File.join(File.dirname(output_dir), ".nojekyll")) &&
        File.file?(File.join(output_dir, ".nojekyll"))
    end

    # Compare two YARD trees after stripping the "Generated on" stamp.
    #
    # Ignores generation timestamps, the YARD gem version, and the footer
    # Ruby patch so a same-content rebuild on a different machine still
    # compares equal.
    #
    # @param left [String]
    # @param right [String]
    # @return [Boolean]
    def equivalent?(left, right)
      left_files = relative_files(left)
      right_files = relative_files(right)
      return false unless left_files == right_files

      left_files.all? do |rel|
        normalize(File.read(File.join(left, rel))) == normalize(File.read(File.join(right, rel)))
      end
    end

    private

    # @param dir [String]
    # @return [Array<String>]
    def relative_files(dir)
      Dir.glob(File.join(dir, "**/*"), File::FNM_DOTMATCH).select { |p| File.file?(p) }
         .map { |p| p.delete_prefix("#{dir}/") }.sort
    end

    # @param text [String]
    # @return [String]
    def normalize(text)
      text.gsub(/Generated on .+ by/, "Generated on DATE by")
          .gsub(/\(ruby-\d+\.\d+\.\d+\)/, "(ruby-VERSION)")
          .gsub(/YARD \d+\.\d+\.\d+/, "YARD X.Y.Z")
          .gsub(/(>yard<\/a>\s+)\d+\.\d+\.\d+/, "\\1X.Y.Z")
    end

    # Pin the YARD footer stamp so a regenerate does not rewrite every page.
    #
    # @param output_dir [String]
    # @return [void]
    def stabilize_html!(output_dir)
      Dir.glob(File.join(output_dir, "**/*.html")).each do |path|
        html = File.read(path).gsub(/Generated on .+ by/, "Generated on DATE by")
        html = unique_changelog_headings(html) if File.basename(path) == "file.CHANGELOG.html"
        File.write(path, html)
      end
    end

    # Preserve the first subsection anchor and qualify repeated ones by release.
    # YARD's Markdown renderer otherwise gives every Added/Fixed heading the same id.
    #
    # @param html [String] generated changelog page.
    # @return [String] HTML with unique subsection ids.
    def unique_changelog_headings(html)
      seen = {}
      release = nil
      html.gsub(/<h([23]) id="([^"]+)">/) do |heading|
        level, id = Regexp.last_match.captures
        release = id if level == "2"
        if level == "3" && seen[id]
          heading.sub(id, "#{release}-#{id}")
        else
          seen[id] = true
          heading
        end
      end
    end
  end
end
