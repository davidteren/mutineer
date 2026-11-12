# frozen_string_literal: true

module Mutineer
  # Filesystem paths as one encoding (#346).
  #
  # With `LANG` and `LC_ALL` unset, Ruby's filesystem encoding is US-ASCII.
  # A non-ASCII name then comes back as ASCII-8BIT, or as US-ASCII with those
  # bytes marked invalid (`Coverage` result keys). The same bytes in two
  # encodings compare unequal, a regexp raises, and `JSON.generate` refuses
  # the string. Read every such path as UTF-8 when the bytes are UTF-8, and
  # as binary otherwise, so both copies share one encoding.
  module FsPath
    # This file, so a coverage subprocess can require the same rule.
    PATH = File.expand_path(__FILE__)

    # `path` as UTF-8 when its bytes are UTF-8, otherwise as binary.
    # ASCII-only text is returned as it is: ASCII encodings already compare
    # equal. `nil` stays `nil`.
    #
    # @param path [String, nil]
    # @return [String, nil]
    def self.read(path)
      return path if path.nil?

      text = String.try_convert(path) || path.to_s
      return text if stable?(text)

      utf8 = text.dup.force_encoding(Encoding::UTF_8)
      return utf8 if utf8.valid_encoding?

      text.dup.force_encoding(Encoding::ASCII_8BIT)
    end

    # True when `text`'s bytes begin with `prefix`'s bytes.
    # Encodings are not compared, so a UTF-8 root and a binary file name
    # do not raise (#346).
    #
    # @param text [String]
    # @param prefix [String]
    # @return [Boolean]
    def self.bytes_start_with?(text, prefix)
      text.to_s.b.start_with?(prefix.to_s.b)
    end

    # `text` without a byte prefix, read again as UTF-8 or binary.
    # `text` itself when the prefix is absent.
    #
    # @param text [String]
    # @param prefix [String]
    # @return [String]
    def self.bytes_delete_prefix(text, prefix)
      raw = text.to_s.b
      pre = prefix.to_s.b
      return read(text) unless raw.start_with?(pre)

      read(raw.byteslice(pre.bytesize..).b)
    end

    # Absolute form of `path`, passed through {read}.
    #
    # @param path [String]
    # @param base [String, nil] directory `path` is relative to.
    # @return [String]
    def self.expand(path, base = nil)
      expanded = base.nil? ? File.expand_path(path) : File.expand_path(path, base)
      read(expanded)
    end

    # `path` tagged the way `Dir.pwd` is tagged in this process.
    #
    # {read} is for comparison and JSON. `load` must use this encoding:
    # Minitest records the path it was given and later calls `delete_prefix`
    # with `"#{Dir.pwd}/"`. Those two encodings differ for a non-ASCII
    # directory under `LC_ALL=C`, and `delete_prefix` raises (#346).
    #
    # @param path [String]
    # @return [String]
    def self.filesystem(path)
      text = read(path)
      tagged = text.dup.force_encoding(Dir.pwd.encoding)
      return tagged if tagged.valid_encoding?

      text.dup.force_encoding(Encoding::ASCII_8BIT)
    end

    # Minitest filters a failure backtrace with a regexp and then shortens
    # the path against Dir.pwd. Under `LC_ALL=C` those lines are US-ASCII
    # with the directory's bytes, so the regexp raises and a killed mutant
    # is reported as an error (#346). Retag each line to {filesystem} first.
    # No-op until Minitest is loaded. Safe to call more than once.
    #
    # @return [void]
    def self.install_minitest_path_filter!
      return unless defined?(::Minitest::BacktraceFilter)
      return if ::Minitest::BacktraceFilter < PathFilter

      ::Minitest::BacktraceFilter.prepend(PathFilter)
    end

    # Prepended onto `Minitest::BacktraceFilter`. See {install_minitest_path_filter!}.
    module PathFilter
      # @param bt [Array<String>, nil]
      # @return [Array<String>]
      def filter(bt)
        return super if bt.nil?

        super(bt.map { |line| FsPath.filesystem(line.to_s) })
      end
    end

    # True when `text` needs no retag: valid UTF-8, or bytes that are ASCII
    # in whatever encoding they carry. An invalid byte sequence is not stable.
    #
    # @param text [String]
    # @return [Boolean]
    def self.stable?(text)
      return true if text.encoding == Encoding::UTF_8 && text.valid_encoding?

      text.ascii_only?
    rescue ArgumentError
      false
    end
    private_class_method :stable?
  end
end
