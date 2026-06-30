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

    # NUL-joined so token delimiters (`||=`, spaces, `::`, `#`) can never collide
    # with the separator; SHA256[0,12] gives a fixed-length, copy-pasteable key.
    def for(subject, mutation, source, occurrence = 0)
      Digest::SHA256.hexdigest(
        [subject.qualified_name, mutation.operator,
         normalized_token(mutation, source), occurrence].join("\x00")
      )[0, 12]
    end

    # Ids for a subject's full mutation list, in input order, assigning each its
    # 0-based occurrence among twins sharing the same (operator, token). This is
    # what disambiguates `a + b + c`'s two `+` mutants without an offset.
    def for_subject(subject, source, mutations)
      seen = Hash.new(0)
      mutations.map do |m|
        key = [m.operator, normalized_token(m, source)]
        occ = seen[key]
        seen[key] += 1
        self.for(subject, m, source, occ)
      end
    end

    # The exact code being mutated, whitespace-collapsed — same normalization the
    # Reporter's diff_for uses for its token label.
    def normalized_token(mutation, source)
      source.byteslice(mutation.start_offset...mutation.end_offset).gsub(/\s+/, " ").strip
    end
  end
end
