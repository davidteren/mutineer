# frozen_string_literal: true

require_relative "test_helper"
require "open3"
require "tmpdir"
require "fileutils"
require "json"

# #346: non-ASCII paths under an ASCII locale, and a source whose magic
# comment names another encoding. The path bug is that the same bytes compare
# unequal (and JSON refuses them) when one copy is US-ASCII or binary and the
# other is UTF-8. The source bug is that a forced UTF-8 read ignores the
# comment, so the mutant cannot be loaded.
class EncodingTest < Minitest::Test
  ROOT = File.expand_path("..", __dir__)
  BIN = File.join(ROOT, "bin", "mutineer")
  FIXTURES = File.expand_path("fixtures/encoding", __dir__)
  RUBY = RbConfig.ruby

  # Forms Ruby accepts, and forms it ignores. The expected name is what
  # `ruby` prints for `__ENCODING__` of a file that starts with that text.
  MAGIC_COMMENTS = {
    "# encoding: EUC-JP\n" => "EUC-JP",
    "# coding: EUC-JP\n" => "EUC-JP",
    "# -*- coding: EUC-JP -*-\n" => "EUC-JP",
    "# vim: set fileencoding=EUC-JP :\n" => "EUC-JP",
    "# vim: fileencoding=EUC-JP\n" => "UTF-8",
    "#!/usr/bin/env ruby\n# encoding: EUC-JP\n" => "EUC-JP",
    "#!/usr/bin/env ruby\r\n# encoding: EUC-JP\r\n" => "EUC-JP",
    "# encoding=EUC-JP\n" => "UTF-8",
    "# encoding = EUC-JP\n" => "EUC-JP",
    "# Encoding: Shift_JIS\n" => "Shift_JIS",
    "# frozen_string_literal: true\n# encoding: EUC-JP\n" => "UTF-8",
    "# encoding: EUC-JP\n# frozen_string_literal: true\n" => "EUC-JP",
    "   # encoding: EUC-JP\n" => "EUC-JP",
    "# coding : utf-8\n" => "UTF-8",
    "# frozen_string_literal: true; encoding: EUC-JP\n" => "EUC-JP",
    "# -*- frozen_string_literal: true; coding: EUC-JP -*-\n" => "EUC-JP",
    "# encoding: ASCII-8BIT\n" => "ASCII-8BIT",
    "# encoding: EUC-JP\r\n" => "EUC-JP"
  }.freeze

  def test_paths_of_one_name_share_one_encoding
    utf8 = "caf\u00e9.rb"
    binary = utf8.b
    us_ascii = utf8.dup.force_encoding(Encoding::US_ASCII)
    refute us_ascii.valid_encoding?
    refute_equal utf8, binary
    refute_equal utf8, us_ascii

    read = [utf8, binary, us_ascii].map { |path| Mutineer::FsPath.read(path) }
    assert_equal [Encoding::UTF_8], read.map(&:encoding).uniq
    assert read.all?(&:valid_encoding?)
    assert_equal [utf8], read.uniq
    assert_raises(JSON::GeneratorError) { JSON.generate(us_ascii => 1) }
    assert_equal({ utf8 => 1 }, JSON.parse(JSON.generate(Mutineer::FsPath.read(us_ascii) => 1)))
  end

  def test_a_path_that_is_not_utf8_stays_binary
    raw = "caf\xFF.rb".b
    us_ascii = raw.dup.force_encoding(Encoding::US_ASCII)
    read = Mutineer::FsPath.read(raw)
    assert_equal Encoding::ASCII_8BIT, read.encoding
    assert_equal read, Mutineer::FsPath.read(us_ascii)
    assert_equal raw, read.b
  end

  def test_project_path_matches_a_binary_spelling_of_a_utf8_name
    Dir.mktmpdir("mutineer-path") do |root|
      File.write(File.join(root, "caf\u00e9.rb"), "")
      absolute = File.join(root, "caf\u00e9.rb").b
      relative = Mutineer::ProjectPath.relative(absolute, root.b)
      assert_equal "caf\u00e9.rb", relative
      assert_equal Encoding::UTF_8, relative.encoding
      assert_equal relative, Mutineer::ProjectPath.relative("caf\u00e9.rb", root)
    end
  end

  # Dir.children under LC_ALL=C returns ASCII-8BIT. A UTF-8 source name must
  # still see the split test; delete_prefix would raise without the retag.
  def test_split_test_matches_a_binary_directory_entry
    Dir.mktmpdir("mutineer-split") do |root|
      FileUtils.mkdir_p(File.join(root, "test"))
      entry = "caf\u00e9_extra_test.rb"
      File.write(File.join(root, "test", entry), "")
      File.write(File.join(root, "caf\u00e9.rb"), "class Cafe; end\n")
      binary = entry.b
      refute_equal entry, binary
      Dir.stub(:children, ->(*) { [binary] }) do
        found = Mutineer::Pairing.infer_tests("caf\u00e9.rb", project_root: root)
        assert_equal ["test/#{entry}"], found
      end
    end
  end

  def test_non_ascii_source_and_test_are_scored_under_an_ascii_locale
    Dir.mktmpdir("mutineer-cafe") do |proj|
      FileUtils.mkdir_p(File.join(proj, "test"))
      File.write(File.join(proj, "caf\u00e9.rb"), <<~SRC)
        class Cafe
          def add(a, b)
            a + b
          end
        end
      SRC
      File.write(File.join(proj, "test", "caf\u00e9_test.rb"), <<~TEST)
        require "minitest/autorun"
        require_relative "../caf\u00e9"
        class CafeTest < Minitest::Test
          def test_add
            assert_equal 3, Cafe.new.add(1, 2)
          end
        end
      TEST
      report = run_json(proj, "caf\u00e9.rb")
      killed = report["killed"]
      assert_equal 1, killed.size
      assert_equal "caf\u00e9.rb", killed[0]["file"]
      assert_equal "Cafe#add", killed[0]["subject"]
      assert_equal "arithmetic", killed[0]["operator"]
      assert_equal "+", killed[0]["token"]
      assert_equal 3, killed[0]["line"]
      assert_equal 0, report["summary"]["no_coverage"]
      assert_equal 0, report["summary"]["errored"]
      assert_equal 100.0, report["summary"]["score"]
    end
  end

  def test_non_ascii_project_folder_is_scored_under_an_ascii_locale
    Dir.mktmpdir("mutineer-folder") do |parent|
      proj = File.join(parent, "caf\u00e9")
      FileUtils.mkdir_p(File.join(proj, "test"))
      File.write(File.join(proj, "calc.rb"), <<~SRC)
        class Calc
          def add(a, b)
            a + b
          end
        end
      SRC
      File.write(File.join(proj, "test", "calc_test.rb"), <<~TEST)
        require "minitest/autorun"
        require_relative "../calc"
        class CalcTest < Minitest::Test
          def test_add
            assert_equal 3, Calc.new.add(1, 2)
          end
        end
      TEST
      report = run_json(proj, "calc.rb")
      assert_equal "calc.rb", report["killed"][0]["file"]
      assert_equal "Calc#add", report["killed"][0]["subject"]
      assert_equal "arithmetic", report["killed"][0]["operator"]
      assert_equal 0, report["summary"]["no_coverage"]
      assert_equal 100.0, report["summary"]["score"]
    end
  end

  def test_non_ascii_folder_scores_an_rspec_example
    Dir.mktmpdir("mutineer-rspec") do |parent|
      proj = File.join(parent, "caf\u00e9")
      FileUtils.mkdir_p(File.join(proj, "spec"))
      File.write(File.join(proj, "calc.rb"), <<~SRC)
        class Calc
          def add(a, b)
            a + b
          end
        end
      SRC
      File.write(File.join(proj, "spec", "calc_spec.rb"), <<~SPEC)
        require "rspec/autorun"
        require_relative "../calc"
        RSpec.describe Calc do
          it "adds" do
            expect(Calc.new.add(1, 2)).to eq(3)
          end
        end
      SPEC
      report = run_json(proj, "calc.rb", test: "spec/calc_spec.rb", framework: "rspec")
      killed = report["killed"]
      assert_equal 1, killed.size
      assert_equal "Calc#add", killed[0]["subject"]
      assert_equal "arithmetic", killed[0]["operator"]
      assert_equal "calc.rb", killed[0]["file"]
      assert_equal 0, report["summary"]["errored"]
      assert_equal 100.0, report["summary"]["score"]
    end
  end

  def test_magic_comment_encoding_matches_ruby
    Dir.mktmpdir("mutineer-magic") do |dir|
      paths = MAGIC_COMMENTS.keys.each_with_index.map do |header, index|
        path = File.join(dir, "f#{index}.rb")
        File.binwrite(path, +"#{header}puts __ENCODING__.name\n")
        path
      end
      script = paths.map { |path| "load #{path.inspect}" }.join("\n")
      out, err, status = Open3.capture3(RUBY, "-e", script)
      assert_equal 0, status.exitstatus, err
      names = out.lines.map(&:strip)
      MAGIC_COMMENTS.each_with_index do |(header, expected), index|
        text = Mutineer::Parser.read(paths[index])
        assert_equal expected, names[index], header
        assert_equal expected, text.encoding.name, header
        assert text.valid_encoding?, header
        assert_equal header.b, text.b.byteslice(0, header.bytesize), header
      end
    end
  end

  def test_euc_jp_source_keeps_its_bytes_and_is_killed
    original = File.binread(File.join(FIXTURES, "eucjp.rb"))
    assert_includes original.bytes, 0xA4
    Dir.mktmpdir("mutineer-eucjp") do |proj|
      source = File.join(proj, "eucjp.rb")
      File.binwrite(source, original)
      FileUtils.cp(File.join(FIXTURES, "eucjp_test.rb"), File.join(proj, "eucjp_test.rb"))

      text = Mutineer::Parser.read(source)
      assert_equal Encoding::EUC_JP, text.encoding
      assert text.valid_encoding?
      assert_equal original, text.b
      plus = text.byteslice(text.byteindex("+"), 1)
      mutation = Mutineer::Mutation.new(start_offset: text.byteindex("+"), end_offset: text.byteindex("+") + 1,
                                        replacement: "-", operator: :arithmetic)
      mutated = mutation.apply(text)
      assert_equal Encoding::EUC_JP, mutated.encoding
      assert mutated.valid_encoding?
      assert_equal original.bytes.count(0xA4), mutated.bytes.count(0xA4)
      refute_equal plus, mutated.byteslice(mutation.start_offset, 1)
      assert_equal "-", mutated.byteslice(mutation.start_offset, 1)

      report = run_json(proj, "eucjp.rb", test: "eucjp_test.rb", env: {})
      killed = report["killed"]
      assert_equal 1, killed.size
      assert_equal "eucjp.rb", killed[0]["file"]
      assert_equal "Calc#add", killed[0]["subject"]
      assert_equal "arithmetic", killed[0]["operator"]
      assert_equal "+", killed[0]["token"]
      assert_equal 4, killed[0]["line"]
      assert_equal 0, report["summary"]["no_coverage"]
      assert_equal 0, report["summary"]["errored"]
      assert_equal original, File.binread(source)
    end
  end

  def test_shift_jis_source_is_tagged_and_not_transcoded
    bytes = "# encoding: Shift_JIS\n# \x82\xA0\n".b
    Dir.mktmpdir("mutineer-sjis") do |dir|
      path = File.join(dir, "sjis.rb")
      File.binwrite(path, bytes)
      text = Mutineer::Parser.read(path)
      assert_equal Encoding::Shift_JIS, text.encoding
      assert text.valid_encoding?
      assert_equal bytes, text.b
    end
  end

  private

  def run_json(proj, source, test: nil, framework: nil, env: { "LC_ALL" => "C", "LANG" => nil })
    args = ["run", source, "--operators", "arithmetic", "--jobs", "1", "--format", "json"]
    args += ["--test", test] if test
    args += ["--framework", framework] if framework
    out, err, status = Open3.capture3(env, RUBY, "-I#{File.join(ROOT, 'lib')}", BIN, *args, chdir: proj)
    assert_equal 0, status.exitstatus, err
    refute_match(/malformed utf-8|invalid byte sequence/i, err)
    JSON.parse(out)
  end
end
