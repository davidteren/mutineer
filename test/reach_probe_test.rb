# frozen_string_literal: true

require_relative "test_helper"
require "json"
require "open3"
require "tempfile"

# The probe is the mechanism behind #345. It writes the sentinel only when
# the wrapped expression runs, and that expression's value stays the value of
# the unwrapped source. Each sibling of a continuation line is a row.
class ReachProbeTest < Minitest::Test
  # name, body, snippet to wrap, call that runs it, call that does not.
  FORMS = [
    ["trailing and", <<~'RUBY', "age > 17", "C.f(true, 20)", "C.f(false, 20)"],
      def self.f(verified, age)
        verified &&
          age > 17
      end
    RUBY
    ["trailing plus", <<~'RUBY', "+", "C.f(true, 1, 2)", "C.f(false)"],
      def self.f(flag, a = 1, b = 2)
        flag && a +
          b
      end
    RUBY
    ["method chain", <<~'RUBY', "upcase", "C.f([User.new('ab')])", "C.f([])"],
      def self.f(users)
        users.map { |u| u.
          name.
          upcase }
      end
    RUBY
    ["multi-line args", <<~'RUBY', "u.length", "C.f(['ab'])", "C.f([])"],
      def self.f(users)
        users.map { |u| format("%d",
          u.length) }
      end
    RUBY
    ["hash", <<~'RUBY', "n + 1", "C.f(true, 1)", "C.f(false, 1)"],
      def self.f(flag, n)
        flag && {
          n: n,
          m: n + 1
        }
      end
    RUBY
    ["heredoc", <<~'RUBY', "n > 0", "C.f(true, 2)", "C.f(false, 2)"],
      def self.f(flag, n)
        flag && <<~TEXT
          #{n > 0}
        TEXT
      end
    RUBY
  ].freeze

  def test_the_probe_records_a_run_and_keeps_the_value
    FORMS.each do |name, body, snippet, reach, miss|
      source = "class C\n#{body}end\n"
      plain = run_source(source, "puts (#{reach}).inspect", json: false)
      wrapped = wrap_snippet(source, snippet)

      assert wrapped, "#{name} did not wrap"
      probed = run_source(wrapped, <<~RUBY, json: true)
        require "json"
        #{miss}
        after_miss = ::File.size(ARGV[1])
        value = #{reach}
        puts JSON.generate(after_miss: after_miss, after_reach: ::File.size(ARGV[1]), value: value.inspect)
      RUBY

      assert_equal plain, probed.fetch("value"), name
      assert_equal 0, probed.fetch("after_miss"), "#{name} recorded a run that did not happen"
      assert_operator probed.fetch("after_reach"), :>, 0, "#{name} did not record the run"
    end
  end

  # A piece of a backslash string is not an expression on its own. The probe
  # climbs to the whole string, which runs exactly when that piece does.
  def test_a_backslash_string_piece_wraps_the_whole_string
    source = <<~'RUBY'
      class C
        def self.f
          "a" \
            "b" \
            "c"
        end
      end
    RUBY
    plain = run_source(source, "puts C.f.inspect", json: false)
    wrapped = wrap_snippet(source, '"b"')
    assert wrapped, "the string piece did not wrap"

    probed = run_source(wrapped, <<~'RUBY', json: true)
      require "json"
      value = C.f
      puts JSON.generate(size: ::File.size(ARGV[1]), value: value.inspect)
    RUBY

    assert_equal plain, probed.fetch("value")
    assert_operator probed.fetch("size"), :>, 0
  end

  # The operand raises before `+` runs. The test sees the exception it
  # expected. The mutated operator never ran, so the sentinel stays empty.
  def test_a_raising_operand_does_not_record_the_operator
    source = <<~'RUBY'
      class C
        def self.f(flag)
          flag &&
            1 + fail("expected")
        end
      end
    RUBY
    wrapped = wrap_snippet(source, "+")
    assert wrapped

    probed = run_source(wrapped, <<~'RUBY', json: true)
      require "json"
      raised = false
      begin
        C.f(true)
      rescue RuntimeError => e
        raised = e.message == "expected"
      end
      puts JSON.generate(raised: raised, size: ::File.size(ARGV[1]))
    RUBY

    assert_equal true, probed.fetch("raised")
    assert_equal 0, probed.fetch("size")
  end

  # A deleted chain link is an empty replacement. The probe sits on the call
  # that remains, and it records a run only when that call runs.
  def test_a_deleted_chain_link_is_recorded_when_the_remaining_call_runs
    source = "class C\n  def self.f(user)\n    user.name.upcase\n  end\nend\n"
    start = source.index(".name")
    mutated = source.byteslice(0, start) + source.byteslice(start + ".name".bytesize..)
    wrapped = Mutineer::ReachProbe.wrap(mutated, start, start, sentinel_path)

    assert wrapped, mutated
    probed = run_source(wrapped, <<~'RUBY', json: true)
      require "json"
      user = User.new("ab")
      before = ::File.size(ARGV[1])
      value = C.f(user)
      puts JSON.generate(before: before, after: ::File.size(ARGV[1]), value: value.inspect)
    RUBY

    assert_equal 0, probed.fetch("before")
    assert_operator probed.fetch("after"), :>, 0
    assert_equal "\"AB\"", probed.fetch("value")
  end

  def wrap_snippet(source, snippet)
    start = source.index(snippet)
    Mutineer::ReachProbe.wrap(source, start, start + snippet.bytesize, sentinel_path)
  end

  # The Tempfile object has to stay referenced. Keeping only its path lets
  # the finalizer unlink the file before the child stats it.
  def sentinel_path
    @sentinel ||= Tempfile.new(["reach-probe-", ".touch"]).tap(&:close)
    @sentinel.path
  end

  # Loads `source` with `load` in a child started under ruby -w. `script` runs
  # after the load. A warning fails the example. The return value is the last
  # stdout line: JSON when the script prints JSON, otherwise that line.
  def run_source(source, script, json:)
    File.write(sentinel_path, "")
    file = Tempfile.new(["reach-src-", ".rb"])
    file.write(HELPER + source)
    file.close
    out, err, status = Open3.capture3(RbConfig.ruby, "-w", "-e", "load ARGV[0]\n#{script}", file.path, sentinel_path)

    assert_predicate status, :success?, "#{err}\n#{out}"
    assert_empty err, err
    line = out.lines.last.to_s.strip
    json ? JSON.parse(line) : line
  end

  HELPER = <<~'RUBY'
    class User
      def initialize(name) = @name = name
      def name = @name
      def upcase = @name.upcase
    end
  RUBY
end
