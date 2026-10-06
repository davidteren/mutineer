# frozen_string_literal: true

require "minitest/autorun"

# Two anonymous test classes with the same method name: Minitest names neither
# class, and the matrix must still tell the two tests apart (#191).
Class.new(Minitest::Test) { def test_same = assert(true) }
Class.new(Minitest::Test) { def test_same = assert(true) }
