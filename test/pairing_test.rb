# frozen_string_literal: true

require_relative "test_helper"
require "tmpdir"
require "fileutils"

# Pure path-logic contract for #11 source->test pairing: no Rails, no process,
# no fork. A plain fixture tree under a tmp dir exercises expansion + inference.
class PairingTest < Minitest::Test
  # Build a project tree from a list of relative paths (each touched as an empty
  # file), yield its root.
  def with_tree(*paths)
    Dir.mktmpdir("mutineer-pair") do |root|
      paths.each do |rel|
        abs = File.join(root, rel)
        FileUtils.mkdir_p(File.dirname(abs))
        FileUtils.touch(abs)
      end
      yield root
    end
  end

  def infer(source, root, prefer: "minitest")
    Mutineer::Pairing.infer_test(source, project_root: root, prefer: prefer)
  end

  def test_app_source_maps_to_test_under_test_dir
    with_tree("app/models/user.rb", "test/models/user_test.rb") do |root|
      assert_equal "test/models/user_test.rb", infer("app/models/user.rb", root)
    end
  end

  def test_lib_source_maps_to_test_dir
    with_tree("lib/billing/invoice.rb", "test/billing/invoice_test.rb") do |root|
      assert_equal "test/billing/invoice_test.rb", infer("lib/billing/invoice.rb", root)
    end
  end

  # lib/ sources also resolve under test/lib/... (the other Rails layout).
  def test_lib_source_resolves_under_test_lib
    with_tree("lib/billing/invoice.rb", "test/lib/billing/invoice_test.rb") do |root|
      assert_equal "test/lib/billing/invoice_test.rb", infer("lib/billing/invoice.rb", root)
    end
  end

  def test_rspec_preference
    with_tree("app/foo/bar.rb", "spec/foo/bar_spec.rb") do |root|
      assert_equal "spec/foo/bar_spec.rb", infer("app/foo/bar.rb", root, prefer: "rspec")
    end
  end

  # A minitest default still finds a spec when that's all that exists (fallback).
  def test_minitest_default_falls_back_to_spec
    with_tree("app/foo/bar.rb", "spec/foo/bar_spec.rb") do |root|
      assert_equal "spec/foo/bar_spec.rb", infer("app/foo/bar.rb", root)
    end
  end

  def test_namespaced_subdirs_preserved
    with_tree("app/services/billing/charge.rb", "test/services/billing/charge_test.rb") do |root|
      assert_equal "test/services/billing/charge_test.rb",
                   infer("app/services/billing/charge.rb", root)
    end
  end

  def test_no_test_on_disk_returns_nil
    with_tree("app/models/user.rb") do |root|
      assert_nil infer("app/models/user.rb", root)
    end
  end

  def test_expand_sources_globs_a_directory
    with_tree("app/a.rb", "app/sub/b.rb", "app/notruby.txt") do |root|
      got = Mutineer::Pairing.expand_sources(["app"], project_root: root)
      assert_equal ["app/a.rb", "app/sub/b.rb"], got
    end
  end

  def test_expand_sources_passes_files_through
    with_tree("app/a.rb") do |root|
      assert_equal ["app/a.rb"], Mutineer::Pairing.expand_sources(["app/a.rb"], project_root: root)
    end
  end

  def test_expand_sources_dedupes_and_mixes_dir_and_file
    with_tree("app/a.rb", "lib/x.rb") do |root|
      got = Mutineer::Pairing.expand_sources(["app", "app/a.rb", "lib/x.rb"], project_root: root)
      assert_equal ["app/a.rb", "lib/x.rb"], got
    end
  end
end
