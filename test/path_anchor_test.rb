# frozen_string_literal: true

require_relative "test_helper"
require "fileutils"
require "json"
require "tmpdir"

# #339: redefine loads the mutated method from a hidden file. In a read-only
# source directory that file is in the system temp directory, so `__dir__`,
# `__FILE__`, and `require_relative` used to follow the temp directory and every
# mutant scored `killed`. The snippet rewrites those anchors to the original
# file. Writable directories and a symlinked source are the same rule.
class RedefinePathAnchorTest < Minitest::Test
  ROOT = File.expand_path("..", __dir__)
  FIXTURE = File.expand_path("fixtures/path_anchor", __dir__)

  # Expressions exercised in one class. The kind is the value the original file
  # would return: the real directory, the loaded path, or the sibling.
  FORMS = [
    ["__dir__", :dir],
    ["Kernel.__dir__", :dir],
    ["::Kernel.__dir__", :dir],
    ["self.__dir__", :dir],
    ["send(:__dir__)", :dir],
    ["__send__(:__dir__)", :dir],
    ['send("__dir__")', :dir],
    ["self.send(:__dir__)", :dir],
    ["__FILE__", :file],
    ["File.dirname(File.expand_path(__FILE__))", :file_dirname],
    ['File.join(__dir__, "anchor.txt")', :anchor_txt],
    ['File.read(File.join(__dir__, "anchor.txt")).strip', :anchor_body],
    ['require_relative "sibling"; ProbeSibling::MARK', :mark],
    ["require_relative(\"sibling\"); ProbeSibling::MARK", :mark],
    ['Kernel.require_relative "sibling"; ProbeSibling::MARK', :mark],
    ["::Kernel.require_relative(\"sibling\"); ProbeSibling::MARK", :mark],
    ['self.require_relative "sibling"; ProbeSibling::MARK', :mark],
    ['send(:require_relative, "sibling"); ProbeSibling::MARK', :mark],
    ['send(:"require_relative", "sibling"); ProbeSibling::MARK', :mark],
    ['self.send(:require_relative, "sibling"); ProbeSibling::MARK', :mark],
    ['name = "sibling"; require_relative name; ProbeSibling::MARK', :mark],
    [%q{require_relative "sib#{'ling'}" ; ProbeSibling::MARK}, :mark],
    ['"__FILE__ __dir__ require_relative"', :literal],
    ['other = Object.new; other.__dir__ rescue "private"', :private]
  ].freeze

  # The loaded method returns the original file's path, while `load` itself
  # still receives the hidden file: beside the source, in the temp directory,
  # or beside a symlink.
  def test_redefine_resolves_path_anchors_to_the_source_file
    %i[writable read_only symlink].each do |mode|
      skip "root can write a read-only dir" if mode == :read_only && Process.uid.zero?

      report = anchor_report(mode)
      assert report["ok"], report["error"]
      report["rows"].each do |row|
        label = "#{mode} #{row["expr"]}"
        assert_nil row["error"], "#{label}: #{row["error"]}"
        assert_equal "Probe339##{row["name"]}", row["owner"], label
        assert_equal 0, row["arity"], label
        assert_equal report["expected"].fetch(row["kind"]), row["value"], label
        assert_match(/\A\.mutineer_mutant/, File.basename(row["loaded"]), label)
        if mode == :read_only
          assert_equal report["tmpdir"], row["loaded_dir"], label
          refute_equal report["real_dir"], row["loaded_dir"], label
        else
          assert_equal report["load_dir"], row["loaded_dir"], label
        end
      end
    end
  end

  # The committed fixture's equivalent mutant survives, and the `*` mutant is
  # killed by the test that calls that method. Writable and read-only agree.
  # Reload on a writable directory agrees too. Reload on a read-only directory
  # cannot write its file, so the mutant is `error`, not a false `killed`.
  def test_fixture_verdicts_for_writable_and_read_only_directories
    writable = run_fixture(FIXTURE, strategy: "redefine")
    assert_anchor_verdicts(writable, "redefine writable")
    assert_equal 1, PathAnchor.instance_method(:via_dir).arity
    assert_equal 1, PathAnchor.instance_method(:via_file).arity
    assert_equal 1, PathAnchor.instance_method(:via_require).arity

    reloaded = run_fixture(FIXTURE, strategy: "reload")
    assert_anchor_verdicts(reloaded, "reload writable")

    skip "root can write a read-only dir" if Process.uid.zero?

    Dir.mktmpdir do |dir|
      copy = File.join(dir, "app")
      FileUtils.cp_r(FIXTURE, copy)
      lib = File.join(copy, "lib")
      File.chmod(0o555, lib)
      readonly = nil
      _out, err = capture_io { readonly = run_fixture(copy, strategy: "redefine") }
      assert_anchor_verdicts(readonly, "redefine read-only")
      refute_match(/is not writable: redefine/, err)

      reloaded_ro = nil
      _out, reload_err = capture_subprocess_io { reloaded_ro = run_fixture(copy, strategy: "reload") }
      assert_match(/EACCES/, reload_err)
      assert(reloaded_ro.results.all? { |result| result.details.to_s.include?("EACCES") })
      assert_equal 0, reloaded_ro.killed_count
      assert_equal 0, reloaded_ro.survived_count
      assert_equal 0, reloaded_ro.covered_count
      assert_nil reloaded_ro.mutation_score
      assert_equal 6, reloaded_ro.errored_count
    ensure
      File.chmod(0o755, lib) if lib && File.directory?(lib)
    end
  end

  private

  def run_fixture(root, strategy:)
    Mutineer::Runner.execute(Mutineer::Config.new(
      sources: [File.join(root, "lib/anchor.rb")],
      tests: [File.join(root, "anchor_test.rb")],
      operators: ["arithmetic"], matrix: true, strategy: strategy, jobs: 1,
      cache_dir: Dir.mktmpdir("mutineer-cache"), project_root: root
    )).first
  end

  def assert_anchor_verdicts(agg, label)
    %w[via_dir via_file via_require].each do |name|
      rows = agg.results.select { |result| result.subject.name.to_s == name }
      assert_equal %w[- /], rows.map { |result| result.mutation.replacement }.sort, "#{label} #{name}"
      survivor = rows.find(&:survived?)
      killed = rows.find(&:killed?)
      assert survivor, "#{label} #{name}: the equivalent + 0 mutant must survive"
      assert_equal "-", survivor.mutation.replacement
      assert_equal :arithmetic, survivor.mutation.operator
      assert_equal "PathAnchor##{name}", survivor.subject.qualified_name
      assert_equal 1, survivor.subject.def_node.parameters.requireds.length
      assert survivor.kills.complete, label
      assert_empty survivor.kills.killed_by.map { |_file, test_name, _id| test_name }

      assert killed, "#{label} #{name}: the * mutant must be killed"
      assert_equal "/", killed.mutation.replacement
      assert_equal "PathAnchor##{name}", killed.subject.qualified_name
      assert killed.kills.complete, label
      assert_equal ["PathAnchorTest#test_#{name}"], killed.kills.killed_by.map { |_file, test_name, _id| test_name }
    end
    assert_equal 0, agg.errored_count, label
  end

  # Runs every form under redefine in a child and returns the paths it observed.
  def anchor_report(mode)
    rd, wr = IO.pipe
    pid = fork do
      rd.close
      wr.write(JSON.generate(probe_mode(mode)))
      wr.close
      exit!(0)
    rescue StandardError => e
      wr.write(JSON.generate("ok" => false, "error" => "#{e.class}: #{e.message}\n#{e.backtrace.first(5).join("\n")}"))
      wr.close
      exit!(1)
    end
    wr.close
    reader = Thread.new { rd.read }
    wait_child(pid)
    JSON.parse(reader.value)
  ensure
    rd&.close
  end

  def probe_mode(mode)
    Dir.mktmpdir do |root|
      real = File.join(root, "real")
      Dir.mkdir(real)
      File.write(File.join(real, "sibling.rb"), "module ProbeSibling; MARK = \"hi\"; end\n")
      File.write(File.join(real, "anchor.txt"), "hi\n")
      File.write(File.join(real, "probe.rb"), probe_source)
      if mode == :symlink
        linkdir = File.join(root, "link")
        Dir.mkdir(linkdir)
        path = File.join(linkdir, "probe.rb")
        File.symlink(File.join(real, "probe.rb"), path)
      else
        path = File.join(real, "probe.rb")
      end
      require path
      location = Probe339.instance_method(:probe_0).source_location.first
      File.chmod(0o555, File.dirname(path)) if mode == :read_only
      source = File.read(path)
      subjects = Mutineer::Project.discover([path])
      original_load = Kernel.instance_method(:load)
      rows = FORMS.each_with_index.map do |(expr, kind), index|
        name = :"probe_#{index}"
        subject = subjects.find { |item| item.name == name }
        body = source.byteslice(subject.def_node.location.start_offset, subject.def_node.location.length)
        keep = body.byteindex(":keep")
        mutation = Mutineer::Mutation.new(
          start_offset: subject.def_node.location.start_offset + keep,
          end_offset: subject.def_node.location.start_offset + keep + ":keep".bytesize,
          replacement: ":keep", operator: :literal_mutation
        )
        loaded = nil
        Mutineer::Isolation.stub(:load, lambda { |load_path|
          loaded = load_path
          original_load.bind_call(Mutineer::Isolation, load_path)
        }) { Mutineer::Isolation.apply_surgical(mutation, subject, source) }
        value = Probe339.new.public_send(name)
        {
          "expr" => expr, "kind" => kind.to_s, "name" => name.to_s, "value" => value,
          "loaded" => loaded, "loaded_dir" => File.realpath(File.dirname(loaded)),
          "owner" => subject.qualified_name,
          "arity" => Probe339.instance_method(name).arity, "error" => nil
        }
      rescue StandardError => e
        { "expr" => expr, "kind" => kind.to_s, "name" => name.to_s, "error" => "#{e.class}: #{e.message}" }
      end
      real_dir = File.dirname(File.realpath(location))
      {
        "ok" => true, "location" => location, "real_dir" => real_dir,
        "load_dir" => File.realpath(File.dirname(path)),
        "tmpdir" => File.realpath(Dir.tmpdir),
        "expected" => {
          "dir" => real_dir,
          "file" => location,
          "file_dirname" => File.dirname(File.expand_path(location)),
          "anchor_txt" => File.join(real_dir, "anchor.txt"),
          "anchor_body" => "hi",
          "mark" => "hi",
          "literal" => "__FILE__ __dir__ require_relative",
          "private" => "private"
        },
        "rows" => rows
      }
    ensure
      File.chmod(0o755, File.dirname(path)) if mode == :read_only && path && File.directory?(File.dirname(path))
    end
  end

  def probe_source
    methods = FORMS.each_with_index.map do |(expr, _), index|
      "  def probe_#{index}\n    x9k = :keep\n    #{expr}\n  end"
    end
    "class Probe339\n#{methods.join("\n")}\nend\n"
  end
end
