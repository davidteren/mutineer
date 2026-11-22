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
    # #493: the value of return, next or a command call. A line break before
    # the wrapper would end that statement and drop the value.
    ["return value", <<~'RUBY', ".first", "C.f(true)", "C.f(false)"],
      def self.f(flag, x = 5)
        return 0 unless flag
        return [x]
          .select { |v| v > 1 }
          .first
      end
    RUBY
    ["next value", <<~'RUBY', ">", "C.f([2])", "C.f([])"],
      def self.f(xs)
        xs.map do |x|
          next x >
            1
        end
      end
    RUBY
    ["command call argument", <<~'RUBY', "+", "C.f(true)", "C.f(false)"],
      def self.keep(v) = v
      def self.f(flag, x = 1)
        return unless flag
        keep x +
          1
      end
    RUBY
    # #493: a wrapper that parses as something else is not used. After a
    # string that a backslash continues, `[` would be an index call on it.
    ["last piece of a backslash string", <<~'RUBY', '""', "C.f(true)", "C.f(false)"],
      def self.f(flag, a = "n")
        flag && a + " is " \
          ""
      end
    RUBY
    # Ruby assigns named captures only when the regexp literal is the receiver.
    ["named capture", <<~'RUBY', '\d+', "C.f(true)", "C.f(false)"],
      def self.f(flag, s = "in 2026")
        flag && (/(?<year>\d+)/ =~ s ? year : nil)
      end
    RUBY
    # A wrapper in place of an assignment target would stop the setter.
    ["assignment target", <<~'RUBY', "x.name", "C.f(true)", "C.f(false)"],
      Pair = Struct.new(:name, :kind)
      def self.f(flag, x = Pair.new)
        flag && (x.name, x.kind = 1, 2)
        x.name
      end
    RUBY
    # The body of `begin ... end until c` runs once before the check. A
    # wrapper around that body would make it a plain value.
    ["do-while body", <<~'RUBY', "n += 1", "C.f(true)", "C.f(false)"],
      def self.f(flag, n = 0)
        return n unless flag
        begin
          n += 1
        end until true
        n
      end
    RUBY
    # A flip-flop in a condition keeps state. Inside the wrapper it is a range.
    ["flip-flop condition", <<~'RUBY', "(x == 2)..(x == 3)", "C.f(true)", "C.f(false)"],
      def self.f(flag)
        return 0 unless flag
        [1, 2, 3].count { |x| ((x == 2)..(x == 3)) ? true : false }
      end
    RUBY
    # A namespace can hold its own Thread constant.
    ["own Thread constant", <<~'RUBY', "a + 1", "C.f(true)", "C.f(false)"],
      Thread = Class.new
      def self.f(flag, a = 1)
        flag && a + 1
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
    start = source.byteindex(".name")
    mutated = source.byteslice(0, start) + source.byteslice(start + ".name".bytesize..)
    wrapped = Mutineer::ReachProbe.wrap(mutated, start, start, sentinel_path, probe_key)

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

  # #493: a caller that reads "the probe did not fire" as evidence asks first
  # if the probe can speak. No probe in the text, or a probe around a jump
  # that leaves the expression before it returns, is not evidence.
  def test_conclusive_needs_the_probe_and_no_jump_in_the_wrapped_expression
    source = "class C\n  def self.f(a)\n    a + 1\n  end\nend\n"
    wrapped = wrap_snippet(source, "a + 1")

    assert Mutineer::ReachProbe.conclusive?(wrapped, probe_key)
    refute Mutineer::ReachProbe.conclusive?(source, probe_key)
    refute Mutineer::ReachProbe.conclusive?(wrapped, Mutineer::ReachProbe.reach_key), "the key of another mutant"
    refute Mutineer::ReachProbe.conclusive?(wrapped, nil)
    refute Mutineer::ReachProbe.conclusive?("class C; end", "C"), "a key of another shape is not a probe"

    # The deletion point of `not` is in the whole modifier statement. Each
    # test that takes the jump leaves the probe silent.
    %w[next break return].each do |jump|
      body = jump == "return" ? "return if  x.ok?" : "xs.each { |x| #{jump} if  x.ok? }"
      text = "class C\n  def self.f(xs, x = nil)\n    #{body}\n  end\nend\n"
      point = text.index("if  x") + 3
      probed = Mutineer::ReachProbe.wrap(text, point, point, sentinel_path, probe_key)
      assert_includes probed, "[(#{jump} if  x.ok?), ", jump
      refute Mutineer::ReachProbe.conclusive?(probed, probe_key), jump
    end

    # A literal raise or throw leaves the expression in the same way.
    %w[raise\ ArgumentError throw\ :stop fail Kernel.raise].each do |call|
      text = "class C\n  def self.f(x)\n    #{call} if  x.ok?\n  end\nend\n"
      point = text.index("if  x") + 3
      probed = Mutineer::ReachProbe.wrap(text, point, point, sentinel_path, probe_key)
      assert_includes probed, "[(#{call} if  x.ok?), ", call
      refute Mutineer::ReachProbe.conclusive?(probed, probe_key), call
    end

    # Ruby never runs the operand of defined?, so a probe there cannot fire.
    operand = "class C\n  def self.f(x)\n    defined?(x.size)\n  end\nend\n"
    probed = wrap_snippet(operand, "x.size")
    assert_includes probed, "defined?([(x.size), "
    refute Mutineer::ReachProbe.conclusive?(probed, probe_key)

    # A bare regexp in a condition matches $_. Inside the wrapper it is a
    # plain value, so the wrap goes around the whole if. (Ruby warns about
    # this form under -w, so it is not a row of FORMS.)
    bare = "class C\n  def self.f\n    if /foo/ then 2 else 1 end\n  end\nend\n"
    assert_includes wrap_snippet(bare, "/foo/"), "[(if /foo/ then 2 else 1 end), "

    # A jump outside the wrapped expression does not matter.
    guard = "class C\n  def self.f(xs)\n    xs.each { |x| next if x > 1 }\n  end\nend\n"
    assert Mutineer::ReachProbe.conclusive?(wrap_snippet(guard, "x > 1"), probe_key)
  end

  # #493: a probe around a block or lambda literal fires when the block is
  # made, not when its body runs. A wrap that cannot stay in the body gives
  # no probe, so the caller has no evidence and keeps the verdict.
  def test_the_wrap_does_not_leave_a_block_or_a_lambda
    {
      "class C\n  def self.f(xs)\n    xs.each { |x| next }\n  end\nend\n" => "next",
      "class C\n  def self.f(h)\n    h[:a] = ->(v) { return v }\n  end\nend\n" => "return v",
      "class C\n  def self.f(c)\n    c << proc do |r|\n      break\n    end\n  end\nend\n" => "break"
    }.each do |source, snippet|
      assert_nil wrap_snippet(source, snippet), snippet
    end

    # An empty body: the deletion point is in the literal itself.
    empty = "class C\n  def self.f(h)\n    h[:a] = ->(v) {}\n  end\nend\n"
    point = empty.index("{}") + 1
    assert_nil Mutineer::ReachProbe.wrap(empty, point, point, sentinel_path, probe_key)

    # A wrap that stays in the body is still made.
    inside = "class C\n  def self.f(xs)\n    xs.each { |x| x + 1 }\n  end\nend\n"
    assert_includes wrap_snippet(inside, "x + 1"), "xs.each { |x| [(x + 1), "
  end

  def wrap_snippet(source, snippet)
    start = source.byteindex(snippet)
    Mutineer::ReachProbe.wrap(source, start, start + snippet.bytesize, sentinel_path, probe_key)
  end

  # The Tempfile object has to stay referenced. Keeping only its path lets
  # the finalizer unlink the file before the child stats it.
  def probe_key
    @probe_key ||= Mutineer::ReachProbe.reach_key
  end

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
