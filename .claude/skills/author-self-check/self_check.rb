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

# Git output and docs are UTF-8 even when LANG is unset.
Encoding.default_external = Encoding::UTF_8

LIMIT = /\b(not yet|limitation|deferred|cannot yet|known gap|out of scope|follow-up|TODO|FIXME)\b/i
ISSUE = /#\d+|issues\/\d+/
ASSERT = /\b(assert\w*|refute\w*|expect\(|must_\w+|wont_\w+)/
WEAKEN = /\b(skip\b|pending\b|xit\b|timeout:\s*\d+)/
COMMENT = %r{\A\s*(#|//|\*|<!--)}
DOC = /\.(md|html|txt|yml)\z/
MIN_WORDS = 6

def git(*args)
  # quotePath=false keeps non-ASCII paths as they are, not quoted.
  out, err, status = Open3.capture3("git", "-c", "core.quotePath=false", *args)
  abort "git #{args.join(' ')} failed: #{err}" unless status.success?
  out
end

# Returns [[path, line], ...] for added (+) or removed (-) lines.
def diff_lines(base, sign)
  path = nil
  header = false # true between "diff --git" and the first "@@" hunk line
  git("diff", "--unified=0", "#{base}...HEAD").scrub.each_line.filter_map do |l|
    header = true if l.start_with?("diff --git ")
    header = false if l.start_with?("@@")
    next unless !header || l.start_with?("+++ b/", "--- a/")

    if header
      path = l[6..].strip if l.start_with?("+++ b/") || sign == "-"
      next
    end
    [path, l[1..].rstrip] if l.start_with?(sign)
  end
end

# Plain words of a doc line or file: no tags, link targets, markup or entities,
# so an .md sentence matches its .html copy.
def plain(text)
  # List markers at a line start do not exist in the HTML copy.
  t = text.gsub(/^\s*(?:[-+]|\d+\.)\s+/, "").gsub(/<[^>]*>/, " ").gsub(/\[([^\]]*)\]\([^)]*\)/, '\1')
  # A removed tag leaves a space before punctuation; drop it so "guide." matches.
  CGI.unescapeHTML(t).tr("’‘“”", "''\"\"").gsub(/[`*_#>|]/, " ").split.join(" ").gsub(/ ([.,;:!?)])/, '\1')
end

base = ARGV[0] || "origin/main"
# Paths in git output are relative to the top level, so run from there.
Dir.chdir(git("rev-parse", "--show-toplevel").strip)
puts "Checking committed changes #{base}...HEAD (#{git("rev-parse", "--short", "HEAD").strip}). Uncommitted edits are not checked."
added = diff_lines(base, "+")
removed = diff_lines(base, "-")
changed = git("diff", "--name-only", "#{base}...HEAD").lines.map(&:strip)

# The skill's own files quote the keywords, so they are not limitations.
own_dir = File.realpath(__dir__).delete_prefix("#{File.realpath(Dir.pwd)}/")
untracked = added.select { |p, l| l.match?(LIMIT) && !l.match?(ISSUE) && !p.to_s.start_with?("#{own_dir}/") }
puts "== Limitations with no issue number (#{untracked.size})"
untracked.each { |p, l| puts "  #{p}: #{l.strip[0, 140]}" }

# A changed assertion is not a weaker test, so count assertions per file.
code = ->(l) { !l.match?(COMMENT) }
test_file = ->(p) { p.to_s.start_with?("test/", "spec/") || p.to_s.match?(%r{\A\.claude/skills/.+_test\.rb\z}) }
weakened = removed.select { |p, l| test_file.(p) && code.(l) && l.match?(ASSERT) }
                  .group_by(&:first)
                  .flat_map do |p, lines|
                    kept = added.count { |q, l| q == p && code.(l) && l.match?(ASSERT) }
                    lines.size > kept ? lines.map { |_, l| [p, "-#{lines.size - kept} net: #{l.strip}"] } : []
                  end
weakened += added.select { |p, l| test_file.(p) && code.(l) && l.match?(WEAKEN) && !l.match?(ASSERT) }.map { |p, l| [p, "+ #{l.strip}"] }
puts "== Tests to justify: net assertions removed, skips or timeouts added (#{weakened.size})"
weakened.each { |p, l| puts "  #{p}: #{l[0, 140]}" }

# Doc sync reads HEAD, the same commit the diff checks, not the working tree.
head_file = ->(p) { git("show", "HEAD:#{p}").scrub }
# -z keeps paths with quotes or backslashes unquoted.
tree = ->(*paths) { git("ls-tree", "-r", "-z", "--name-only", "HEAD", *paths).split("\0") }
docs = tree.().select { |p| p.match?(DOC) && p != "CHANGELOG.md" }
corpus = docs.to_h { |p| [p, plain(head_file.(p))] }
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
# An .html or .txt copy that a rake task names is probably built by it.
rake_text = tree.("Rakefile", "rake").map(&head_file).join
mark = ->(p) { p.match?(/\.(html|txt)\z/) && rake_text.include?(File.basename(p)) ? "#{p} (named in rake/, rebuild if generated)" : p }
puts "== Doc sync: removed text still in another doc, or twin not changed (#{stale.size + twins.size})"
puts "   Answer each line: updated, or differs because ..." unless stale.empty? && twins.empty?
stale.each { |p, t, o| puts "  #{p}: \"#{t[0, 100]}\" still in #{o.map(&mark).join(', ')}" }
twins.each { |t| puts "  #{t}" }

exit(untracked.empty? ? 0 : 1)
