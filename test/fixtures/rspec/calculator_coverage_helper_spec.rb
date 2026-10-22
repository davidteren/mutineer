# frozen_string_literal: true

require "coverage"
raise "the spec helper failed to load" unless Coverage.running?

require_relative "calculator_strong_spec"
