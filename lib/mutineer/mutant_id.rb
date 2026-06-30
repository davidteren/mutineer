# frozen_string_literal: true

require "digest"

module Mutineer
  # Content-based stable id for a mutant — NOT byte offsets. Pure function, reused
  # by the Runner (matching the ignore list), the Reporter (emitting a copy-
  # pasteable id per survivor), and #13 baseline gating (diffing id-sets run to
  # run). `digest` is stdlib, so zero new deps.
  #
  # Offset-free by design: keyed on the subject's qualified_name (a method, not a
  # byte position) + operator + the normalized mutated token + an occurrence
  # ordinal among same-(operator, token) twins WITHIN the subject. So it survives
  # any edit outside the subject method — where raw start/end offsets shift on
  # every edit earlier in the file and would silently stop matching.
  module MutantId
    module_function

    # Computes the stable id for a single mutant.
    #
    # NUL-joined so token delimiters (`||=`, spaces, `::`, `#`) can never collide
    # with the separator; SHA256[0,12] gives a fixed-length, copy-pasteable key.
    #
    # @param subject [Mutineer::Subject] the subject (method) the mutant lives in;
    #   its `qualified_name` anchors the id to a method rather than a byte position.
    # @param mutation [Mutineer::Mutation] the atomic edit whose operator is hashed.
    # @param source [String] the full, unmutated source the mutation indexes into.
    # @param occurrence [Integer] 0-based ordinal among twins sharing the same
    #   (operator, token) within the subject, disambiguating otherwise-identical mutants.
    # @return [String] a 12-character hex id, stable across edits outside the subject.
    def for(subject, mutation, source, occurrence = 0)
      Digest::SHA256.hexdigest(
        [subject.qualified_name, mutation.operator,
         normalized_token(mutation, source), occurrence].join("\x00")
      )[0, 12]
    end

    # Computes ids for a subject's full mutation list, in input order, assigning
    # each its 0-based occurrence among twins sharing the same (operator, token).
    # This is what disambiguates `a + b + c`'s two `+` mutants without an offset.
    #
    # @param subject [Mutineer::Subject] the subject the mutations belong to.
    # @param source [String] the full, unmutated source for token normalization.
    # @param mutations [Array<Mutineer::Mutation>] the subject's mutations, in order.
    # @return [Array<String>] one 12-character id per mutation, positionally aligned.
    def for_subject(subject, source, mutations)
      seen = Hash.new(0)
      mutations.map do |m|
        key = [m.operator, normalized_token(m, source)]
        occ = seen[key]
        seen[key] += 1
        self.for(subject, m, source, occ)
      end
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
