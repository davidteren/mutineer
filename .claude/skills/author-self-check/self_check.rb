#!/usr/bin/env ruby
# frozen_string_literal: true

# Mechanical part of the author self-check. Prints what a person must look at;
# it does not judge. Exit 1 when it finds an untracked limitation.
#
#   ruby self_check.rb [base]        # base defaults to origin/main
#
# Checks the lines this branch adds or removes against base:
# 1. An added line that names a limitation and no issue number.
# 2. A test file that loses assertions, or gains a skip or a timeout.
# 3. Doc sync: text the branch removed from a doc that another doc still has,
#    and a doc whose .md or .html twin the branch did not change. A copy that
#    a rake task names is marked, so you rebuild it instead of editing it.
require "open3"
require "cgi"

LIMIT = /\b(not yet|limitation|deferred|cannot yet|known gap|out of scope|follow-up|TODO|FIXME)\b/i
ISSUE = /#\d+|issues\/\d+/
ASSERT = /\b(assert\w*|refute\w*|expect\(|must_\w+|wont_\w+)/
WEAKEN = /\b(skip\b|pending\b|xit\b|timeout:\s*\d+)/
COMMENT = %r{\A\s*(#|//|\*|<!--)}
DOC = /\.(md|html|txt|yml)\z/
MIN_WORDS = 6

def git(*args)
  out, err, status = Open3.capture3("git", *args)
  abort "git #{args.join(' ')} failed: #{err}" unless status.success?
  out
end

# Returns [[path, line], ...] for added (+) or removed (-) lines.
def diff_lines(base, sign)
  path = nil
  git("diff", "--unified=0", "#{base}...HEAD").each_line.filter_map do |l|
    path = l[6..].strip if l.start_with?("+++ b/")
    path = l[6..].strip if l.start_with?("--- a/") && sign == "-"
    next if l.start_with?("+++", "---")

    [path, l[1..].rstrip] if l.start_with?(sign)
  end
end

# Plain words of a doc line or file: no tags, link targets, markup or entities,
# so an .md sentence matches its .html copy.
def plain(text)
  t = text.gsub(/<[^>]*>/, " ").gsub(/\[([^\]]*)\]\([^)]*\)/, '\1')
  CGI.unescapeHTML(t).tr("’‘“”", "''\"\"").gsub(/[`*_#>|]/, " ").split.join(" ")
end

base = ARGV[0] || "origin/main"
added = diff_lines(base, "+")
removed = diff_lines(base, "-")
changed = git("diff", "--name-only", "#{base}...HEAD").lines.map(&:strip)

untracked = added.select { |_, l| l.match?(LIMIT) && !l.match?(ISSUE) }
puts "== Limitations with no issue number (#{untracked.size})"
untracked.each { |p, l| puts "  #{p}: #{l.strip[0, 140]}" }

# A changed assertion is not a weaker test, so count assertions per file.
code = ->(l) { !l.match?(COMMENT) }
test_file = ->(p) { p.to_s.start_with?("test/", "spec/") }
weakened = removed.select { |p, l| test_file.(p) && code.(l) && l.match?(ASSERT) }
                  .group_by(&:first)
                  .flat_map do |p, lines|
                    kept = added.count { |q, l| q == p && code.(l) && l.match?(ASSERT) }
                    lines.size > kept ? lines.map { |_, l| [p, "-#{lines.size - kept} net: #{l.strip}"] } : []
                  end
weakened += added.select { |p, l| test_file.(p) && code.(l) && l.match?(WEAKEN) && !l.match?(ASSERT) }.map { |p, l| [p, "+ #{l.strip}"] }
puts "== Tests to justify: net assertions removed, skips or timeouts added (#{weakened.size})"
weakened.each { |p, l| puts "  #{p}: #{l[0, 140]}" }

# Doc sync. The tree is the checked-out HEAD.
docs = git("ls-files").lines.map(&:strip).select { |p| p.match?(DOC) && File.file?(p) && p != "CHANGELOG.md" }
corpus = docs.to_h { |p| [p, plain(File.read(p, encoding: "UTF-8").scrub)] }
stale = removed.filter_map do |p, l|
  next unless p.to_s.match?(DOC) && p != "CHANGELOG.md"

  text = plain(l)
  next if text.split.size < MIN_WORDS || corpus[p]&.include?(text)

  others = corpus.select { |q, body| q != p && body.include?(text) }.keys
  [p, text, others] unless others.empty?
end
twins = changed.select { |p| p.start_with?("docs/") && p.match?(/\.(md|html)\z/) }.filter_map do |p|
  twin = p.sub(/\.(md|html)\z/) { Regexp.last_match(1) == "md" ? ".html" : ".md" }
  "#{p} changed, #{twin} did not" if corpus.key?(twin) && !changed.include?(twin)
end
# Docs a rake task names are probably built by it.
rake_text = git("ls-files", "Rakefile", "rake").lines.map(&:strip).select { |p| File.file?(p) }.map { |p| File.read(p) }.join
mark = ->(p) { rake_text.include?(File.basename(p)) ? "#{p} (named in rake/, rebuild if generated)" : p }
puts "== Doc sync: removed text still in another doc, or twin not changed (#{stale.size + twins.size})"
puts "   Answer each line: updated, or differs because ..." unless stale.empty? && twins.empty?
stale.each { |p, t, o| puts "  #{p}: \"#{t[0, 100]}\" still in #{o.map(&mark).join(', ')}" }
twins.each { |t| puts "  #{t}" }

exit(untracked.empty? ? 0 : 1)
