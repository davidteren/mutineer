# frozen_string_literal: true

# What a Rails boot does before any mutant fork (`config.encoding`, which
# assigns both). External alone does not put UTF-8 on a new file; both do,
# on Ruby 3.4 and 4.0. Loading the source here keeps the child's `require`
# from reloading the original over the mutant.
Encoding.default_external = Encoding::UTF_8
Encoding.default_internal = Encoding::UTF_8
require_relative "binary_body"
