# frozen_string_literal: true

require "minitest/autorun"
require "open3"
require "tmpdir"

# `rake yard:strict` is the documentation gate. It must fail on an undocumented
# object, and it must leave no file behind: the HTML it used to write to doc/
# made review hooks report YARD's own template.
class YardStrictTest < Minitest::Test
  # The repository Rakefile. With -f, rake stays in the directory it starts in.
  RAKEFILE = File.expand_path("../Rakefile", __dir__)

  # Runs the task on a project that holds only lib/thing.rb.
  # @param source [String] the Ruby source of lib/thing.rb
  # @return [Array(String, Process::Status, Array<String>)] the output, the exit
  #   status, and each path in the project after the run
  def yard_strict(source)
    Dir.mktmpdir do |dir|
      FileUtils.mkdir(File.join(dir, "lib"))
      File.write(File.join(dir, "lib/thing.rb"), source)
      out, status = Open3.capture2e("bundle", "exec", "rake", "-f", RAKEFILE, "yard:strict", chdir: dir)
      [out, status, Dir.glob("**/*", File::FNM_DOTMATCH, base: dir).reject { |path| path.end_with?(".") }.sort]
    end
  end

  def test_a_documented_project_passes_and_the_task_writes_no_file
    out, status, paths = yard_strict("# A thing.\nmodule Thing\nend\n")
    assert status.success?, out
    assert_match(/100\.00% documented/, out)
    assert_equal %w[lib lib/thing.rb], paths, "yard:strict must write no doc/ and no .yardoc/"
  end

  def test_an_undocumented_private_method_fails_the_task
    out, status, = yard_strict("# A thing.\nmodule Thing\n  private\n\n  def bare; end\nend\n")
    refute status.success?, out
    assert_match(/yard:strict failed: [\d.]+% documented/, out)
  end
end
