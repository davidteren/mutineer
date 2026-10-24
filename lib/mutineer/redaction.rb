# frozen_string_literal: true

require "uri"

module Mutineer
  # Hides database credentials in text bound for a terminal: an error reply,
  # a log line, a warning. Rails parses DATABASE_URL itself, so an error about
  # a malformed one can quote the whole URL. Outside a URL a password of 3
  # characters or fewer is hidden only as a whole word, so it cannot blank
  # letters inside other words. A password that exactly equals the username is
  # left visible outside a URL, so `role "postgres"` stays readable.
  #
  # Stdlib only: the app-side daemon loads this file without the rest of
  # mutineer.
  module Redaction
    # The password in a `scheme://user:password@host` URL. Greedy up to the last
    # `@` before an unescaped quote or line end, so a malformed password with a
    # space, an unescaped `@`, or a quote `inspect` escaped (`\"`) is hidden too.
    URL_PASSWORD = %r{([a-z][a-z0-9+.\-]*://[^\s:/@"'\\]*):(?:\\.|[^"'\r\n\\])*@}i
    # What replaces a hidden password.
    REDACTED = "[REDACTED]"
    # What {text} returns when it fails: never the input, which may hold the
    # password.
    FAILED = "[message hidden: redaction failed]"
    # An ASCII word character, the edge a whole-word match must not touch.
    WORD_CHAR = "[A-Za-z0-9_]"
    # The longest password form hidden only as a whole word. A longer form is
    # hidden wherever it appears, even glued to an escape such as `%40` or
    # `\x41`: failing toward hiding too much is safer for a long secret.
    SHORT_FORM = 3

    module_function

    # Hide the password in any URL, and the DATABASE_URL password wherever it
    # appears: whole, percent-decoded, `inspect` escaped, or cut short after
    # its `scheme://user:` prefix. Outside a URL a form of {SHORT_FORM}
    # characters or fewer is hidden only as a whole word. Never raises: text in
    # any encoding comes back as UTF-8, and an internal error returns {FAILED}.
    #
    # @param text [#to_s]
    # @param env [Hash{String => String}] where DATABASE_URL is read.
    # @return [String]
    def text(text, env: ENV)
      out = utf8(text.to_s)
      head, raw = database_url_parts(utf8(env["DATABASE_URL"].to_s))
      secrets = raw ? password_forms(raw) : []
      # Prefixes first, on the caller's text, so no replacement made here can
      # be mistaken for part of a password.
      [head, head&.inspect&.[](1...-1)].compact.uniq.each do |prefix|
        out = secrets.reduce(out) { |acc, secret| redact_prefixes(acc, prefix, secret) }
      end
      out = out.gsub(URL_PASSWORD) { "#{Regexp.last_match(1)}:#{REDACTED}@" }
      # A password that exactly equals the username is left visible outside a
      # URL. The username is not a secret: mutineer prints it in every
      # redacted URL, so the value is already shown, and blanking it would
      # hide every role and database name in a `postgres:postgres` setup. The
      # skip needs an exact raw match: a password that only shares a form or a
      # prefix with the username is a separate secret and stays hidden.
      return out if head && raw == head[(head.index("://") + 3)...-1]

      secrets.reduce(out) do |acc, secret|
        secret.length > SHORT_FORM ? acc.gsub(secret, REDACTED) : redact_word(acc, secret)
      end
    rescue StandardError
      FAILED
    end

    # A UTF-8 copy of `str` that every pattern here can match. Valid UTF-8 and
    # ASCII-only text is returned as is. Binary text, or text whose bytes are
    # invalid in its own encoding, is read as UTF-8 with bad bytes replaced.
    # Other valid text is converted, with characters UTF-8 lacks replaced.
    #
    # @param str [String]
    # @return [String]
    def utf8(str)
      return str if str.ascii_only? || (str.encoding == Encoding::UTF_8 && str.valid_encoding?)
      return String.new(str, encoding: Encoding::UTF_8).scrub if str.encoding == Encoding::BINARY || !str.valid_encoding?

      str.encode(Encoding::UTF_8, invalid: :replace, undef: :replace)
    end

    # Replace `form` in `text` only where it is a whole word: no ASCII word
    # character touches an edge of `form` that is itself a word character.
    #
    # @param text [String]
    # @param form [String] one form of the password.
    # @return [String]
    def redact_word(text, form)
      pattern = Regexp.escape(form)
      pattern = "(?<!#{WORD_CHAR})#{pattern}" if form.match?(/\A#{WORD_CHAR}/o)
      pattern = "#{pattern}(?!#{WORD_CHAR})" if form.match?(/#{WORD_CHAR}\z/o)
      text.gsub(Regexp.new(pattern), REDACTED)
    end

    # Split DATABASE_URL into its `scheme://user:` head and its raw password.
    # Read by position, not URI or a pattern, because the URL may be the
    # malformed one and its password may hold any character: the password runs
    # from the first `:` after `scheme://` to the last `@`.
    #
    # @param url [String]
    # @return [Array(String, String), nil]
    def database_url_parts(url)
      start = url.index("://")
      at = url.rindex("@")
      return unless start && at

      colon = url.index(":", start + 3)
      return unless colon && colon < at

      raw = url[(colon + 1)...at]
      [url[0..colon], raw] unless raw.empty?
    end

    # The password as it may appear in a message: raw, percent-decoded, and
    # each `inspect` escaped. Longest first, so a longer form is replaced
    # before a form it contains.
    #
    # @param raw [String]
    # @return [Array<String>]
    def password_forms(raw)
      decoded = begin
        # Decoding can yield invalid UTF-8 (`%E4`); scrub it like the text.
        utf8(URI.decode_www_form_component(raw.gsub("+", "%2B")))
      rescue ArgumentError
        raw
      end
      [raw, decoded].flat_map { |form| [form, form.inspect[1...-1]] }
                    .uniq.reject(&:empty?).sort_by { |form| -form.length }
    end

    # Hide what follows each `head` while it matches the start of `secret`,
    # for a message that cut the URL short inside the password.
    #
    # @param text [String]
    # @param head [String] the DATABASE_URL `scheme://user:` prefix, raw or
    #   `inspect` escaped.
    # @param secret [String]
    # @return [String]
    def redact_prefixes(text, head, secret)
      out = +""
      pos = 0
      while (found = text.index(head, pos))
        start = found + head.length
        length = 0
        length += 1 while length < secret.length && text[start + length] == secret[length]
        out << text[pos...start] << (length.positive? ? REDACTED : "")
        pos = start + length
      end
      out << text[pos..]
    end
  end
end
