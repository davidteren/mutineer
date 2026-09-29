# frozen_string_literal: true

require "digest"

module Mutineer
  # Content-based id for a mutant — NOT byte offsets. Pure function, reused
  # by the Runner (matching the ignore list), the Reporter (emitting a copy-
  # pasteable id per survivor), and #13 baseline gating (diffing id-sets run to
  # run). `digest` is stdlib, so zero new deps.
  #
  # Offset-free by design: keyed on the subject's project-relative file path +
  # qualified_name (a method, not a byte position) + operator + the normalized
  # mutated token + an occurrence ordinal among same-(operator, token) twins
  # WITHIN the subject + (only when positive) the subject's ordinal among
  # same-named subjects in its file. So it survives any edit outside the subject method,
  # where raw start/end offsets shift on every edit earlier in the file and
  # would silently stop matching. Moving or renaming the file changes the id.
  module MutantId
    module_function

    # Computes the stable id for a single mutant.
    #
    # NUL-joined so token delimiters (`||=`, spaces, `::`, `#`) can never collide
    # with the separator; `SHA256[0,12]` gives a fixed-length, copy-pasteable key.
    # The file path is part of the key, so the same qualified name in two files
    # (an owner-less `def`, or a class reopened elsewhere) cannot collide. `path`
    # is required so no caller can get the colliding legacy id by accident.
    #
    # @param subject [Mutineer::Subject] the subject (method) the mutant lives in;
    #   its `qualified_name` anchors the id to a method rather than a byte position.
    # @param mutation [Mutineer::Mutation] the atomic edit whose operator is hashed.
    # @param source [String] the full, unmutated source the mutation indexes into.
    # @param occurrence [Integer] 0-based ordinal among twins sharing the same
    #   (operator, token) within the subject, disambiguating otherwise-identical mutants.
    # @param path [String] the subject's file, normalized with {ProjectPath.relative}
    #   against the project root (an absolute real path when outside the root).
    # @param subject_ordinal [Integer] 0-based ordinal among subjects in the same
    #   file sharing this qualified name (two owner-less `def index` in two DSL
    #   blocks). Hashed only when positive, so a subject whose name is unique in
    #   its file keeps the id it had without it.
    # @return [String] a 12-character hex id, stable across edits outside the subject.
    def for(subject, mutation, source, occurrence = 0, path:, subject_ordinal: 0)
      parts = [path, subject.qualified_name, mutation.operator, normalized_token(mutation, source), occurrence]
      parts << subject_ordinal if subject_ordinal.positive?
      digest(parts)
    end

    # Computes ids for a subject's full mutation list, in input order, assigning
    # each its 0-based occurrence among twins sharing the same (operator, token).
    # This is what disambiguates `a + b + c`'s two `+` mutants without an offset.
    #
    # @param subject [Mutineer::Subject] the subject the mutations belong to.
    # @param source [String] the full, unmutated source for token normalization.
    # @param mutations [Array<Mutineer::Mutation>] the subject's mutations, in order.
    # @param path [String] the subject's normalized file path (see {.for}).
    # @param subject_ordinal [Integer] the subject's ordinal among same-named
    #   subjects in its file (see {.for}).
    # @return [Array<String>] one 12-character id per mutation, positionally aligned.
    def for_subject(subject, source, mutations, path:, subject_ordinal: 0)
      with_occurrences(mutations, source) do |m, occ|
        self.for(subject, m, source, occ, path: path, subject_ordinal: subject_ordinal)
      end
    end

    # The pre-1.3 id: the {.for} formula without the path, so it collides across
    # files. Kept only to match ignore entries and baselines stored in the old
    # format; removed in 2.0.
    #
    # @param subject [Mutineer::Subject] the subject (method) the mutant lives in.
    # @param mutation [Mutineer::Mutation] the atomic edit whose operator is hashed.
    # @param source [String] the full, unmutated source the mutation indexes into.
    # @param occurrence [Integer] 0-based ordinal among same-(operator, token) twins.
    # @return [String] a 12-character hex id in the old format.
    def legacy_for(subject, mutation, source, occurrence = 0)
      digest([subject.qualified_name, mutation.operator,
              normalized_token(mutation, source), occurrence])
    end

    # {.for_subject} for the pre-1.3 id format (see {.legacy_for}).
    #
    # @param subject [Mutineer::Subject] the subject the mutations belong to.
    # @param source [String] the full, unmutated source for token normalization.
    # @param mutations [Array<Mutineer::Mutation>] the subject's mutations, in order.
    # @return [Array<String>] one old-format id per mutation, positionally aligned.
    def legacy_for_subject(subject, source, mutations)
      with_occurrences(mutations, source) { |m, occ| legacy_for(subject, m, source, occ) }
    end

    # Maps each mutation to the block's result, passing its 0-based occurrence
    # among earlier mutations with the same (operator, token).
    #
    # @param mutations [Array<Mutineer::Mutation>] the subject's mutations, in order.
    # @param source [String] the full, unmutated source for token normalization.
    # @yieldparam mutation [Mutineer::Mutation] the current mutation.
    # @yieldparam occurrence [Integer] its ordinal among same-(operator, token) twins.
    # @return [Array] the block's results, positionally aligned.
    def with_occurrences(mutations, source)
      seen = Hash.new(0)
      mutations.map do |m|
        key = [m.operator, normalized_token(m, source)]
        occ = seen[key]
        seen[key] += 1
        yield m, occ
      end
    end

    # NUL-joins the id parts and returns the first 12 hex chars of their SHA256.
    #
    # @param parts [Array] the values that make up the id.
    # @return [String] a 12-character hex id.
    def digest(parts)
      Digest::SHA256.hexdigest(parts.join("\x00"))[0, 12]
    end

    # Extracts the exact code being mutated, whitespace-collapsed — the same
    # normalization the Reporter's `diff_for` uses for its token label.
    #
    # @param mutation [Mutineer::Mutation] supplies the byte range to slice.
    # @param source [String] the source to byteslice (byte offsets, never char).
    # @return [String] the mutated token with runs of whitespace collapsed to one space.
    def normalized_token(mutation, source)
      source.byteslice(mutation.start_offset...mutation.end_offset).gsub(/\s+/, " ").strip
    end
  end
end
