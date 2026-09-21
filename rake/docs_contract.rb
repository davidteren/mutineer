# frozen_string_literal: true

require "cgi"
require "yaml"

# Single-source the exit-code contract and generate derived docs surfaces.
module DocsContract
  ROOT = File.expand_path("..", __dir__)
  CONTRACT_PATH = File.join(ROOT, "docs/fragments/contract.yml")
  SCHEMA_MD = File.join(ROOT, "docs/json-schema.md")
  SCHEMA_HTML = File.join(ROOT, "docs/json-schema.html")
  LLMS_FULL = File.join(ROOT, "docs/llms-full.txt")

  # Heading text in json-schema.md → stable HTML ids (keep existing anchors).
  HEADING_IDS = {
    "Versioning contract" => "versioning",
    "Top-level shape" => "shape",
    "`summary` (object)" => "summary",
    "`survivors[]` (array of object)" => "survivors",
    "`no_coverage[]` and `uncapturable[]` (array of object)" => "other-statuses",
    "`no_verdict[]` (array of object)" => "no-verdict",
    "`ignored[]` (array of object)" => "ignored",
    "`per_source[]` (array of object)" => "per-source",
    "`baseline` (object, only with `--baseline`)" => "baseline",
    "Exit codes" => "exit-codes"
  }.freeze

  # Table aria-labels the Playwright suite already asserts.
  TABLE_ARIA = {
    "summary" => "Summary fields",
    "survivors" => "Survivor fields",
    "baseline" => "Baseline fields",
    "exit-codes" => "Exit codes"
  }.freeze

  # TOC labels matching the current schema page.
  TOC_LABELS = {
    "versioning" => "Versioning contract",
    "shape" => "Top-level shape",
    "summary" => "summary",
    "survivors" => "survivors[]",
    "other-statuses" => "no_coverage / uncapturable",
    "no-verdict" => "no_verdict[]",
    "ignored" => "ignored[]",
    "per-source" => "per_source[]",
    "baseline" => "baseline",
    "exit-codes" => "Exit codes"
  }.freeze

  MARKED = %w[
    README.md
    docs/json-schema.md
    docs/agentic-coding.md
    docs/skill.md
    docs/index.md
  ].freeze

  class << self
    # Parsed contract.yml.
    #
    # @return [Hash]
    def contract
      @contract ||= YAML.safe_load_file(CONTRACT_PATH)
    end

    # Canonical Markdown exit-code table.
    #
    # @return [String]
    def exit_codes_markdown
      rows = contract.fetch("exit_codes").map do |row|
        "| `#{row.fetch('code')}` | #{row.fetch('meaning')} |"
      end
      ["| Code | Meaning |", "|------|---------|", *rows].join("\n")
    end

    # Canonical HTML exit-code table (for hand-maintained pages).
    #
    # @return [String]
    def exit_codes_html
      rows = contract.fetch("exit_codes").map do |row|
        %(<tr><td class="op">#{row.fetch('code')}</td><td>#{inline(row.fetch('meaning'))}</td></tr>)
      end
      <<~HTML.chomp
        <div class="table-wrap" tabindex="0" role="region" aria-label="Exit codes">
          <table>
            <thead><tr><th scope="col">Code</th><th scope="col">Meaning</th></tr></thead>
            <tbody>
              #{rows.join("\n              ")}
            </tbody>
          </table>
        </div>
      HTML
    end

    # Concatenated agent ingest file.
    #
    # @return [String]
    def llms_full_txt
      readme = File.read(File.join(ROOT, "README.md"))
      readme = readme.gsub("(docs/", "(")
      readme = readme.gsub("[LICENSE](LICENSE)",
        "[LICENSE](https://github.com/davidteren/mutineer/blob/main/LICENSE)")
      agentic = File.read(File.join(ROOT, "docs/agentic-coding.md"))
      schema = File.read(SCHEMA_MD)
      <<~TXT
        # Mutineer — full documentation

        > Concatenated from README, the AI-agents/CI guide, and the JSON report schema.
        > Source: https://github.com/davidteren/mutineer

        ---

        # README

        #{readme.rstrip}

        ---

        #{agentic.rstrip}

        ---

        #{schema.rstrip}
      TXT
    end

    # Render `docs/json-schema.html` from `docs/json-schema.md`.
    #
    # @return [String]
    def json_schema_html
      md = File.read(SCHEMA_MD)
      body, toc = render_schema_article(md)
      page_wrap(body, toc)
    end

    # Apply the contract to every derived surface and write them.
    #
    # @return [void]
    def generate!
      apply_markers!
      write!(LLMS_FULL, llms_full_txt)
      write!(SCHEMA_HTML, json_schema_html)
    end

    # Derived paths that do not match a fresh generate.
    #
    # @return [Array<String>]
    def stale_files
      stale = []
      MARKED.each do |rel|
        path = File.join(ROOT, rel)
        stale << rel unless File.read(path) == with_exit_codes(File.read(path), :markdown)
      end
      html = File.join(ROOT, "docs/agentic-coding.html")
      stale << "docs/agentic-coding.html" unless File.read(html) == with_exit_codes(File.read(html), :html)
      stale << "README.md" unless threshold_applied?(File.read(File.join(ROOT, "README.md")))
      stale << "action.yml" unless action_applied?(File.read(File.join(ROOT, "action.yml")))
      stale << "docs/llms-full.txt" unless File.read(LLMS_FULL) == "#{llms_full_txt.rstrip}\n"
      stale << "docs/json-schema.html" unless File.read(SCHEMA_HTML) == json_schema_html
      stale
    end

    # Plain-text meaning for one exit code (for drift assertions).
    #
    # @param code [String]
    # @return [String]
    def meaning_plain(code)
      row = contract.fetch("exit_codes").find { |r| r.fetch("code") == code.to_s }
      raise "unknown exit code #{code}" unless row

      row.fetch("meaning").gsub(/`/, "").gsub("**", "")
    end

    private

    # Inject generated tables / descriptions into marked files.
    #
    # @return [void]
    def apply_markers!
      MARKED.each do |rel|
        path = File.join(ROOT, rel)
        write!(path, with_exit_codes(File.read(path), :markdown))
      end
      html = File.join(ROOT, "docs/agentic-coding.html")
      write!(html, with_exit_codes(File.read(html), :html))
      write!(File.join(ROOT, "README.md"), apply_threshold_row(File.read(File.join(ROOT, "README.md"))))
      write!(File.join(ROOT, "action.yml"), apply_action(File.read(File.join(ROOT, "action.yml"))))
    end

    # Replace a contract include block.
    #
    # @param text [String]
    # @param kind [Symbol] :markdown or :html
    # @return [String]
    def with_exit_codes(text, kind)
      name = kind == :html ? "exit-codes-html" : "exit-codes"
      body = kind == :html ? exit_codes_html : exit_codes_markdown
      replace_section(text, name, body)
    end

    # @param text [String]
    # @param name [String]
    # @param body [String]
    # @return [String]
    def replace_section(text, name, body)
      start = "<!-- contract:#{name} -->"
      stop = "<!-- /contract:#{name} -->"
      pattern = /#{Regexp.escape(start)}.*?#{Regexp.escape(stop)}/m
      replace_exactly_once(text, pattern, "#{name} markers") do
        "#{start}\n#{body.chomp}\n#{stop}"
      end
    end

    # Replace `pattern` once. Raises if the target is missing or ambiguous
    # so `docs:generate` cannot silently leave a stale copy in place.
    #
    # @param text [String]
    # @param pattern [Regexp]
    # @param label [String]
    # @yieldparam match [MatchData]
    # @return [String]
    def replace_exactly_once(text, pattern, label)
      count = text.scan(pattern).length
      raise "#{label}: target missing — cannot apply the contract" if count.zero?
      raise "#{label}: matched #{count} times, expected 1" if count != 1

      text.sub(pattern) { yield Regexp.last_match }
    end

    # @param text [String]
    # @return [Boolean]
    def threshold_applied?(text)
      text.include?("| `--threshold FLOAT` | #{contract.fetch('threshold_readme')} |")
    end

    # Rewrite the README options-table row keyed by the `--threshold FLOAT`
    # flag column, not the generated meaning cell.
    #
    # @param text [String]
    # @return [String]
    def apply_threshold_row(text)
      replace_exactly_once(
        text,
        /^\| `--threshold FLOAT` \|.*\|$/,
        "README --threshold row"
      ) do
        "| `--threshold FLOAT` | #{contract.fetch('threshold_readme')} |"
      end
    end

    # @param text [String]
    # @return [Boolean]
    def action_applied?(text)
      text.include?(contract.fetch("threshold_action")) &&
        text.include?(contract.fetch("exit_code_action"))
    end

    # Rewrite Action descriptions keyed by YAML field names, not prose.
    #
    # @param text [String]
    # @return [String]
    def apply_action(text)
      text = replace_exactly_once(
        text,
        /^(  threshold:\n    description: ).+$/,
        "action.yml threshold description"
      ) { |match| "#{match[1]}#{contract.fetch('threshold_action').inspect}" }
      replace_exactly_once(
        text,
        /^(  exit-code:\n    description: ).+$/,
        "action.yml exit-code description"
      ) { |match| "#{match[1]}#{contract.fetch('exit_code_action').inspect}" }
    end

    # Render the schema article. Supported Markdown only: ATX `##`/`###`
    # headings, fenced code, pipe tables, `- ` lists (wrapped
    # continuations), paragraphs, HTML comments (skipped), and the one
    # "A consumer should accept" callout. Other constructs are not
    # rendered — keep `json-schema.md` inside this subset, and assert
    # published HTML against the markdown source (not only a self-render).
    #
    # @param md [String]
    # @return [Array(String, String)] article HTML and TOC HTML
    def render_schema_article(md)
      lines = md.lines.map(&:chomp)
      chunks = []
      toc = []
      last_id = nil
      i = 0
      while i < lines.length
        line = lines[i]
        if line.empty?
          i += 1
        elsif line.start_with?("<!--")
          i += 1
        elsif line.start_with?("```")
          fence = [line]
          i += 1
          while i < lines.length && !lines[i].start_with?("```")
            fence << lines[i]
            i += 1
          end
          fence << lines[i] if i < lines.length
          i += 1
          chunks << render_fence(fence)
        elsif (m = line.match(/^(\#{1,3})\s+(.+)$/))
          depth = m[1].length
          title = m[2]
          if depth == 1
            i += 1
            next
          end
          id = HEADING_IDS[title] || title.downcase.gsub(/[^a-z0-9]+/, "-").gsub(/^-|-$/, "")
          last_id = id
          toc << %(<li><a href="##{id}">#{TOC_LABELS[id] || CGI.escapeHTML(title.gsub('`', ''))}</a></li>)
          tag = "h2"
          chunks << "<#{tag} id=\"#{id}\">#{inline(title)}</#{tag}>"
          i += 1
        elsif line.start_with?("|")
          table = []
          while i < lines.length && lines[i].start_with?("|")
            table << lines[i]
            i += 1
          end
          chunks << render_table(table, last_id)
        elsif line.start_with?("- ")
          items = []
          while i < lines.length && (lines[i].start_with?("- ") || lines[i].match?(/\A\s+\S/))
            if lines[i].start_with?("- ")
              items << lines[i].sub(/^- /, "")
            else
              items[-1] = "#{items[-1]} #{lines[i].strip}"
            end
            i += 1
          end
          lis = items.map { |item| "<li>#{inline(item)}</li>" }.join
          chunks << "<ul>#{lis}</ul>"
        else
          para = []
          while i < lines.length && !lines[i].empty? && !lines[i].start_with?("#", "|", "- ", "```")
            para << lines[i]
            i += 1
          end
          text = para.join(" ")
          chunks << if text.start_with?("A consumer should accept")
            %(<div class="callout"><span class="ico" aria-hidden="true">!</span><p>#{inline(text)}</p></div>)
          else
            "<p>#{inline(text)}</p>"
          end
        end
      end
      first_p = chunks.index { |c| c.start_with?("<p>") }
      chunks[first_p] = chunks[first_p].sub("<p>", '<p class="doc-lede">') if first_p
      [chunks.join("\n      "), toc.join("\n        ")]
    end

    # @param fence [Array<String>]
    # @return [String]
    def render_fence(fence)
      body = fence[1..-2].join("\n")
      "<pre><code>#{CGI.escapeHTML(body)}</code></pre>"
    end

    # @param table [Array<String>]
    # @param heading_id [String, nil]
    # @return [String]
    def render_table(table, heading_id)
      rows = table.reject { |line| separator_row?(line) }.map do |line|
        cells = split_row(line)
        cells.map { |c| c.strip }
      end
      header, *body = rows
      thead = header.map { |c| %(<th scope="col">#{inline(c)}</th>) }.join
      tbody = body.map do |cells|
        tds = cells.each_with_index.map do |c, idx|
          klass = if idx == 0
            "op"
          elsif cells.length > 2 && idx == 1
            "rule"
          end
          klass ? %(<td class="#{klass}">#{inline(c)}</td>) : "<td>#{inline(c)}</td>"
        end
        "<tr>#{tds.join}</tr>"
      end.join
      label = TABLE_ARIA[heading_id] || header.first
      <<~HTML.chomp
        <div class="table-wrap" tabindex="0" role="region" aria-label="#{label}">
          <table>
            <thead><tr>#{thead}</tr></thead>
            <tbody>#{tbody}</tbody>
          </table>
        </div>
      HTML
    end

    # Markdown alignment row (`|---|:---|`).
    #
    # @param line [String]
    # @return [Boolean]
    def separator_row?(line)
      split_row(line).all? { |cell| cell.strip.match?(/\A:?-+:?\z/) }
    end

    # Split a Markdown table row, honoring `\|`.
    #
    # @param line [String]
    # @return [Array<String>]
    def split_row(line)
      line = line.sub(/^\|/, "").sub(/\|\s*$/, "")
      line.split(/(?<!\\)\|/).map { |c| c.gsub('\\|', '|') }
    end

    # Inline Markdown → HTML.
    #
    # @param text [String]
    # @return [String]
    def inline(text)
      codes = []
      text = text.gsub(/`([^`]+)`/) { codes << Regexp.last_match(1); "%%CODE#{codes.length - 1}%%" }
      links = []
      text = text.gsub(/\[([^\]]+)\]\(([^)]+)\)/) do
        links << [Regexp.last_match(1), Regexp.last_match(2)]
        "%%LINK#{links.length - 1}%%"
      end
      text = CGI.escapeHTML(text)
      text = text.gsub(/\*\*(.+?)\*\*/, '<strong>\\1</strong>')
      text = text.gsub(/(?<!\*)\*(?!\*)(.+?)(?<!\*)\*(?!\*)/, '<em>\\1</em>')
      links.each_with_index do |(label, href), idx|
        href = href.sub(%r{\A\./}, "").sub(/\.md\z/, ".html")
        text = text.gsub("%%LINK#{idx}%%", %(<a href="#{CGI.escapeHTML(href)}">#{CGI.escapeHTML(label)}</a>))
      end
      codes.each_with_index do |code, idx|
        text = text.gsub("%%CODE#{idx}%%", "<code>#{CGI.escapeHTML(code)}</code>")
      end
      text
    end

    # Chrome around the generated article.
    #
    # @param article [String]
    # @param toc [String]
    # @return [String]
    def page_wrap(article, toc)
      <<~HTML
        <!DOCTYPE html>
        <html lang="en" data-theme="dark">
        <head>
        <meta charset="utf-8">
        <meta name="viewport" content="width=device-width, initial-scale=1">
        <title>Mutineer JSON report — schema reference</title>
        <meta name="description" content="The machine-readable contract for `mutineer run --format json`: versioning rules and a field-by-field reference for summary, survivors, baseline, and exit codes.">
        <meta name="color-scheme" content="dark light">
        <link rel="canonical" href="https://davidteren.github.io/mutineer/json-schema.html">
        <link rel="alternate" type="text/markdown" href="https://davidteren.github.io/mutineer/json-schema.md" title="Markdown">
        <meta property="og:type" content="article">
        <meta property="og:site_name" content="Mutineer">
        <meta property="og:title" content="Mutineer JSON report — schema reference">
        <meta property="og:description" content="The machine-readable contract for `mutineer run --format json`: versioning rules and a field-by-field reference for summary, survivors, baseline, and exit codes.">
        <meta property="og:url" content="https://davidteren.github.io/mutineer/json-schema.html">
        <meta property="og:image" content="https://davidteren.github.io/mutineer/assets/og-image-20260908.png">
        <meta property="og:image:width" content="1200">
        <meta property="og:image:height" content="630">
        <meta property="og:image:alt" content="Mutineer — Make your tests prove it. Ruby mutation testing with Prism and stdlib.">
        <meta name="twitter:card" content="summary_large_image">
        <meta name="twitter:title" content="Mutineer JSON report — schema reference">
        <meta name="twitter:description" content="The machine-readable contract for `mutineer run --format json`: versioning rules and a field-by-field reference for summary, survivors, baseline, and exit codes.">
        <meta name="twitter:image" content="https://davidteren.github.io/mutineer/assets/og-image-20260908.png">
        <meta name="twitter:image:alt" content="Mutineer — Make your tests prove it. Ruby mutation testing with Prism and stdlib.">
        <link rel="icon" href="data:image/svg+xml,%3Csvg xmlns='http://www.w3.org/2000/svg' viewBox='0 0 32 32'%3E%3Crect width='32' height='32' rx='1' fill='%2367286a'/%3E%3Ctext x='16' y='23' font-family='monospace' font-size='20' font-weight='700' text-anchor='middle' fill='%23fff'%3EM%3C/text%3E%3C/svg%3E">
        <script src="assets/mutineer.js?v=c3f78ebce1ef"></script>
        <link rel="stylesheet" href="assets/mutineer.css?v=421d8b2a5030">
        </head>
        <body>
        <a class="skip" href="#main">Skip to content</a>

        <header class="site">
          <div class="wrap nav">
            <a class="brand" href="index.html"><span class="mark" aria-hidden="true">M↗</span> mutineer<span class="brand-note">/ Ruby mutation testing</span></a>
            <nav aria-label="Primary">
              <a href="index.html#install">Install</a>
              <a href="agentic-coding.html">Agent &amp; CI</a>
              <a href="json-schema.html" aria-current="page">JSON schema</a>
              <a href="api/">API</a>
              <a href="sample-report.html">Sample report</a>
              <a href="https://github.com/davidteren/mutineer" rel="noopener">GitHub ↗</a>
              <button class="toggle" id="theme" aria-label="Switch to light mode" hidden>◐ <span>Dark</span></button>
            </nav>
          </div>
        </header>

        <main id="main" class="wrap">
          <div class="doc-layout">
            <aside class="doc-side">
              <div class="toc-title">On this page</div>
              <ul>
                #{toc}
              </ul>
              <div class="doc-nav-pages">
                <a href="agentic-coding.html">Agent &amp; CI</a>
                <a href="json-schema.html" class="current" aria-current="page">JSON schema</a>
              </div>
            </aside>

            <article class="prose">
              <span class="eyebrow"><span class="dot" aria-hidden="true"></span> Reference · schema_version 1.3</span>
              <h1>JSON report schema reference</h1>
              #{article}
              <div class="callout"><span class="ico" aria-hidden="true">→</span><p>See the <a href="agentic-coding.html">agent &amp; CI recipes</a> for how to consume this in a loop or a PR gate.</p></div>
            </article>
          </div>
        </main>

        <footer>
          <div class="wrap foot">
            <div>
              <strong>Mutineer</strong> — clean-room mutation testing for Ruby.
              <div class="note">MIT licensed · Prism + stdlib only · © David Teren</div>
            </div>
            <nav aria-label="Footer">
              <a href="index.html">Home</a>
              <a href="agentic-coding.html">Agent &amp; CI recipes</a>
              <a href="api/">API</a>
              <a href="https://github.com/davidteren/mutineer" rel="noopener">GitHub</a>
              <a href="#main">Top ↑</a>
            </nav>
          </div>
        </footer>

        </body>
        </html>
      HTML
    end

    # @param path [String]
    # @param contents [String]
    # @return [void]
    def write!(path, contents)
      File.write(path, contents.end_with?("\n") ? contents : "#{contents}\n")
    end
  end
end
