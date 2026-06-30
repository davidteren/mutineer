# frozen_string_literal: true

module Mutineer
  # Source -> test pairing by path convention (#11). Pure stdlib path logic:
  # no Rails, no class loading, no process. Two jobs:
  #   * expand_sources — a directory argument becomes its sorted **/*.rb files.
  #   * infer_test     — a source's test file by convention (app/ and lib/ sources
  #                      map to test/.../_test.rb or spec/.../_spec.rb), preserving
  #                      namespaced subdirectories. First EXISTING candidate wins.
  #
  # Independently unit-testable: every method is pure in/out over the filesystem,
  # so the pairing contract is exercised with plain fixtures, no Rails, no fork.
  module Pairing
    module_function

    # Expand each positional source: a directory -> its sorted **/*.rb files
    # (relative to project_root); a file (or glob, or anything non-directory) ->
    # itself. Flattened, deduped, order-stable.
    def expand_sources(args, project_root:)
      root = File.expand_path(project_root)
      Array(args).flat_map do |arg|
        abs = File.expand_path(arg, root)
        if File.directory?(abs)
          Dir.glob(File.join(abs, "**", "*.rb")).sort.map { |f| f.delete_prefix("#{root}/") }
        else
          [arg]
        end
      end.uniq
    end

    # The first EXISTING candidate test path for a source (relative to
    # project_root), or nil. `prefer` is the resolved framework ("minitest" |
    # "rspec"): its candidates are tried first, the other framework's as fallback,
    # so a minitest default still finds a spec and vice-versa.
    def infer_test(source_rel, project_root:, prefer: "minitest")
      base, lib = logical_path(source_rel)
      candidates(base, lib, prefer).find do |rel|
        File.exist?(File.expand_path(rel, project_root))
      end
    end

    # Strip the source root to a logical path (no ".rb") and flag lib/ sources.
    # app/foo/bar.rb and lib/foo/bar.rb both -> "foo/bar"; anything else -> the
    # path minus ".rb" (still attempted). Namespaced subdirs are preserved
    # verbatim — structural, never constant resolution.
    def logical_path(source_rel)
      no_ext = source_rel.sub(/\.rb\z/, "")
      if no_ext.start_with?("app/")
        [no_ext.sub(%r{\Aapp/}, ""), false]
      elsif no_ext.start_with?("lib/")
        [no_ext.sub(%r{\Alib/}, ""), true]
      else
        [no_ext, false]
      end
    end

    # Ordered candidate test paths. lib/ sources also get test/lib/... and
    # spec/lib/... (Rails apps put lib tests under either layout).
    def candidates(base, lib, prefer)
      minitest = ["test/#{base}_test.rb"]
      minitest << "test/lib/#{base}_test.rb" if lib
      rspec = ["spec/#{base}_spec.rb"]
      rspec << "spec/lib/#{base}_spec.rb" if lib
      prefer == "rspec" ? rspec + minitest : minitest + rspec
    end
  end
end
