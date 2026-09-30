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

  def infer_tests(source, root, prefer: "minitest")
    Mutineer::Pairing.infer_tests(source, project_root: root, prefer: prefer)
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

  def test_source_maps_to_test_prefix_file
    with_tree("lib/foo/bar.rb", "test/foo/test_bar.rb") do |root|
      assert_equal "test/foo/test_bar.rb", infer("lib/foo/bar.rb", root)
    end
  end

  def test_lib_source_maps_to_test_prefix_file_under_test_lib
    with_tree("lib/foo/bar.rb", "test/lib/foo/test_bar.rb") do |root|
      assert_equal "test/lib/foo/test_bar.rb", infer("lib/foo/bar.rb", root)
    end
  end

  def test_helper_source_does_not_pair_with_test_helper
    with_tree("lib/helper.rb", "test/test_helper.rb") do |root|
      assert_nil infer("lib/helper.rb", root)
    end
  end

  def test_suffix_file_wins_over_prefix_file
    with_tree("lib/calc.rb", "test/calc_test.rb", "test/test_calc.rb") do |root|
      assert_equal "test/calc_test.rb", infer("lib/calc.rb", root)
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

  # #87: a suite split as <basename>_*_test.rb still pairs when the exact file
  # is absent. Order is sorted so the choice is stable.
  def test_split_test_files_pair_when_no_exact_file_exists
    with_tree("app/foo/bar.rb", "test/foo/bar_upsert_test.rb", "test/foo/bar_guards_test.rb") do |root|
      assert_equal ["test/foo/bar_guards_test.rb", "test/foo/bar_upsert_test.rb"],
                   infer_tests("app/foo/bar.rb", root)
      assert_equal "test/foo/bar_guards_test.rb", infer("app/foo/bar.rb", root)
    end
  end

  def test_exact_test_file_unions_with_split_files_and_stays_first
    with_tree("app/foo/bar.rb", "test/foo/bar_test.rb", "test/foo/bar_guards_test.rb") do |root|
      assert_equal ["test/foo/bar_test.rb", "test/foo/bar_guards_test.rb"],
                   infer_tests("app/foo/bar.rb", root)
    end
  end

  def test_prefix_file_unions_with_split_files
    with_tree("lib/foo/bar.rb", "test/foo/test_bar.rb", "test/foo/bar_guards_test.rb") do |root|
      assert_equal ["test/foo/test_bar.rb", "test/foo/bar_guards_test.rb"],
                   infer_tests("lib/foo/bar.rb", root)
    end
  end

  # bar_*_test.rb must not swallow barbecue_test.rb, the exact bar_test.rb, or
  # a file nested in a subdirectory.
  def test_split_names_do_not_match_a_longer_basename_or_a_nested_file
    with_tree("app/foo/bar.rb", "test/foo/barbecue_test.rb", "test/foo/bar_test.rb",
              "test/foo/nested/bar_extra_test.rb") do |root|
      assert_equal ["test/foo/bar_test.rb"], infer_tests("app/foo/bar.rb", root)
    end
  end

  def test_lib_source_finds_split_files_under_test_and_test_lib
    with_tree("lib/billing/invoice.rb",
              "test/billing/invoice_zeta_test.rb",
              "test/lib/billing/invoice_alpha_test.rb") do |root|
      assert_equal ["test/billing/invoice_zeta_test.rb", "test/lib/billing/invoice_alpha_test.rb"],
                   infer_tests("lib/billing/invoice.rb", root)
    end
  end

  # A spec the old rules already find stays the only file. Split Minitest names
  # must not replace it or join it.
  def test_spec_fallback_is_not_joined_or_replaced_by_split_files
    with_tree("app/foo/bar.rb", "spec/foo/bar_spec.rb", "test/foo/bar_guards_test.rb") do |root|
      assert_equal ["spec/foo/bar_spec.rb"], infer_tests("app/foo/bar.rb", root)
      assert_equal ["spec/foo/bar_spec.rb"], infer_tests("app/foo/bar.rb", root, prefer: "rspec")
    end
  end

  def test_split_files_still_pair_when_rspec_is_preferred_and_no_spec_exists
    with_tree("app/foo/bar.rb", "test/foo/bar_guards_test.rb") do |root|
      assert_equal ["test/foo/bar_guards_test.rb"],
                   infer_tests("app/foo/bar.rb", root, prefer: "rspec")
    end
  end

  def test_helper_source_ignores_test_helper_but_pairs_a_real_split_file
    with_tree("lib/helper.rb", "test/test_helper.rb") do |root|
      assert_nil infer("lib/helper.rb", root)
    end
    with_tree("lib/helper.rb", "test/helper_extra_test.rb") do |root|
      assert_equal ["test/helper_extra_test.rb"], infer_tests("lib/helper.rb", root)
    end
  end
end
