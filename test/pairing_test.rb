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

  # #104: equivalent spellings of one file name the same root-relative path,
  # so they pair with the same test and run once.
  def test_expand_sources_normalizes_equivalent_file_paths
    with_tree("lib/calc.rb", "test/calc_test.rb") do |root|
      spellings = ["lib/calc.rb", "./lib/calc.rb", File.join(root, "lib/calc.rb"), "lib/../lib/calc.rb"]
      spellings.each do |arg|
        assert_equal ["lib/calc.rb"], Mutineer::Pairing.expand_sources([arg], project_root: root), arg
      end
      assert_equal ["lib/calc.rb"], Mutineer::Pairing.expand_sources(spellings, project_root: root)
      assert_equal ["test/calc_test.rb"], infer_tests("lib/calc.rb", root)
    end
  end

  def test_expand_sources_keeps_a_path_outside_the_root_as_typed
    with_tree("proj/lib/calc.rb", "other/x.rb") do |dir|
      root = File.join(dir, "proj")
      assert_equal ["../other/x.rb"], Mutineer::Pairing.expand_sources(["../other/x.rb"], project_root: root)
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

  def test_app_source_does_not_claim_a_test_lib_file
    with_tree("lib/models/user.rb", "app/models/user_session.rb",
              "test/lib/models/user_session_guards_test.rb") do |root|
      assert_equal ["test/lib/models/user_session_guards_test.rb"],
                   infer_tests("lib/models/user.rb", root)
      assert_empty infer_tests("app/models/user_session.rb", root)
    end
  end

  def test_lib_longer_source_still_claims_a_test_lib_file
    with_tree("lib/models/user.rb", "lib/models/user_session.rb",
              "test/lib/models/user_session_guards_test.rb") do |root|
      assert_empty infer_tests("lib/models/user.rb", root)
      assert_equal ["test/lib/models/user_session_guards_test.rb"],
                   infer_tests("lib/models/user_session.rb", root)
    end
  end

  # ../../widget.rb searches the parent of the project. The file there is a
  # real split match, and the guard must reject that directory. ../widget.rb
  # collapses onto the project root, so it never sees this file.
  def test_split_search_stays_inside_the_project
    parent = Dir.mktmpdir
    root = File.join(parent, "proj")
    FileUtils.mkdir_p(root)
    File.write(File.join(parent, "widget_extra_test.rb"), "class T; end\n")
    assert_empty infer_tests("../../widget.rb", root)
  ensure
    FileUtils.remove_entry(parent) if parent && File.directory?(parent)
  end

  # A root of "/" must not build the prefix "//", or every child is rejected.
  def test_inside_project_accepts_a_child_of_the_filesystem_root
    assert Mutineer::Pairing.inside_project?("/widget", "/")
    assert Mutineer::Pairing.inside_project?("/", "/")
    refute Mutineer::Pairing.inside_project?("/tmp/proj-evil", "/tmp/proj")
    assert Mutineer::Pairing.inside_project?("/tmp/proj/test", "/tmp/proj")
  end

  # user_session__test.rb is not an exact test or a split test for
  # user_session.rb. user.rb keeps it.
  def test_double_underscore_split_stays_with_the_shorter_source
    with_tree("app/models/user.rb", "app/models/user_session.rb",
              "test/models/user_session__test.rb") do |root|
      assert_equal ["test/models/user_session__test.rb"], infer_tests("app/models/user.rb", root)
      assert_empty infer_tests("app/models/user_session.rb", root)
    end
  end

  def test_split_file_is_left_for_the_longer_source_when_that_file_exists
    with_tree("app/models/user.rb", "app/models/user_session.rb",
              "test/models/user_session_test.rb") do |root|
      assert_empty infer_tests("app/models/user.rb", root)
      assert_equal ["test/models/user_session_test.rb"],
                   infer_tests("app/models/user_session.rb", root)
    end
  end

  def test_longer_source_outside_app_and_lib_keeps_its_split_file
    with_tree("src/user.rb", "src/user_session.rb", "test/src/user_session_test.rb") do |root|
      assert_empty infer_tests("src/user.rb", root)
      assert_equal ["test/src/user_session_test.rb"], infer_tests("src/user_session.rb", root)
    end
  end

  def test_root_source_does_not_take_a_longer_sibling_test
    with_tree("user.rb", "user_session.rb", "test/user_session_test.rb") do |root|
      assert_empty infer_tests("user.rb", root)
      assert_equal ["test/user_session_test.rb"], infer_tests("user_session.rb", root)
    end
  end

  def test_intermediate_source_owns_a_longer_split_name
    with_tree("app/foo/bar.rb", "app/foo/bar_upsert.rb",
              "test/foo/bar_upsert_guards_test.rb") do |root|
      assert_empty infer_tests("app/foo/bar.rb", root)
      assert_equal ["test/foo/bar_upsert_guards_test.rb"],
                   infer_tests("app/foo/bar_upsert.rb", root)
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
