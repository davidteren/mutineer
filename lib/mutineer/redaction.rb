# frozen_string_literal: true

require "uri"

module Mutineer
  # Hides database credentials in text bound for a terminal: an error reply,
  # a log line, a warning. Rails parses DATABASE_URL itself, so an error about
  # a malformed one can quote the whole URL. Outside a URL a password form
  # made only of word characters is hidden only as a whole token, so it cannot
  # blank letters inside other words (#341). A password that exactly equals the
  # username is left visible outside a URL, so `role "postgres"` stays readable.
  #
  # Stdlib only: the app-side daemon loads this file without the rest of
  # mutineer.
  module Redaction
    # The password in a `scheme://user:password@host` URL. It ends at the last
    # `@` before an unescaped quote or line end that starts a host: a run with
    # no `@`, then a `/`, `:`, `?` or `#`, and no other `@` before the next
    # space. So in `u:p@ss@h/db and p@ss` only `p@ss` is hidden (#341). With no
    # such `@`, it ends at the last `@`, as before. A malformed password with
    # an `@`, a `:`, a space, or a quote `inspect` escaped (`\"`) is hidden
    # too, so when the two goals conflict, hiding wins: in
    # `u:pw@h/x and y@h2/db` the text up to `h2` is hidden. One case still
    # shows part of a password: one that holds an `@`, a host, a `/`, `:`,
    # `?` or `#`, and a space (`a@b/c d`), in a URL whose own host has no
    # port, path or query.
    URL_PASSWORD = %r{
      ([a-z][a-z0-9+.\-]*://[^\s:/@"'\\]*):
      (?:
        (?:\\.|[^"'\r\n\\])*@(?=[^@\s"'\\/:?\#]+[/:?\#][^@\s]*(?:\s|\z))
      | (?:\\.|[^"'\r\n\\])*@
      )
    }xi
    # What replaces a hidden password.
    REDACTED = "[REDACTED]"
    # What {text} returns when it fails: never the input, which may hold the
    # password.
    FAILED = "[message hidden: redaction failed]"
    # An ASCII word character, the edge a whole-token match must not touch.
    WORD_CHAR = "[A-Za-z0-9_]"
    # The longest password form hidden only as a whole token whatever its
    # characters. A longer form with a non-word character is hidden wherever
    # it appears, because its edges are no reliable token boundary.
    SHORT_FORM = 3
    # An escape or prefix that glues a word character to the left of a
    # password form in a message: `%40`, `\x41`, `\u0041`, `\u{41}`, `\101`,
    # `\n`, an ANSI colour code as Rails logs colour a span (raw, or escaped
    # as `\e`, `\033`, `\x1b` or `\u001b`), or a `-p` flag
    # (`mysql -ps3cret`). A form right after one is still a whole token.
    ESCAPE = /%\h{2}|\\x\h{2}|\\u(?:\h{4}|\{\h+\})|\\[0-7]{1,3}|(?:\e|\\(?:e|033|x1[bB]|u001[bB]))\[[0-9;]*m|\\[a-z]|(?<!\S)-p/.source

    module_function

    # Hide the password in any URL, and the DATABASE_URL password (from its
    # `user:password@` pair and from its `password=` query parameter) wherever
    # it appears: whole, percent-decoded, `inspect` escaped, or cut short after
    # its `scheme://user:` prefix. Outside a URL a form of word characters, or
    # of {SHORT_FORM} characters or fewer, is hidden only as a whole token; a
    # longer form with another character is hidden anywhere. Never raises: text in
    # any encoding comes back as UTF-8, and an internal error returns {FAILED}.
    #
    # @param text [#to_s]
    # @param env [Hash{String => String}] where DATABASE_URL is read.
    # @return [String]
    def text(text, env: ENV)
      out = utf8(text.to_s)
      url = utf8(env["DATABASE_URL"].to_s)
      # Two readings of the userinfo: up to the last `@` (a malformed password
      # may hold any character) and up to the last `@` before the path (a
      # query value may hold an `@`). Both are hidden: hiding too much is safe.
      parts = [database_url_parts(url), database_url_parts(authority(url))].compact.uniq
      # Prefixes first, on the caller's text, so no replacement made here can
      # be mistaken for part of a password.
      parts.each do |head, raw|
        forms = password_forms(raw)
        [head, head.inspect[1...-1]].uniq.each do |prefix|
          out = forms.reduce(out) { |acc, secret| redact_prefixes(acc, prefix, secret) }
        end
      end
      out = out.gsub(URL_PASSWORD) { "#{Regexp.last_match(1)}:#{REDACTED}@" }
      # A password that exactly equals the username is left visible outside a
      # URL. The username is not a secret: mutineer prints it in every
      # redacted URL, so the value is already shown, and blanking it would
      # hide every role and database name in a `postgres:postgres` setup. The
      # skip needs an exact raw match: a password that only shares a form or a
      # prefix with the username is a separate secret and stays hidden. A
      # `password=` query parameter, which Rails prefers, is always hidden.
      raws = parts.reject { |head, raw| raw == head[(head.index("://") + 3)...-1] }.map(&:last)
      raws.concat(query_passwords(url))
      secrets = raws.compact.uniq.flat_map { |raw| password_forms(raw) }.uniq.sort_by { |form| -form.length }
      secrets.reduce(out) do |acc, secret|
        whole_token = secret.length <= SHORT_FORM || secret.match?(/\A#{WORD_CHAR}+\z/)
        whole_token ? redact_word(acc, secret) : acc.gsub(secret, REDACTED)
      end
    rescue StandardError
      FAILED
    end

    # A UTF-8 copy of `str` that every pattern here can match. Valid UTF-8 and
    # ASCII-only text is returned as is. Binary text, or ASCII-compatible text
    # whose bytes are invalid in its own encoding, is read as UTF-8 with bad
    # bytes replaced. Other text (including UTF-16 and UTF-32, valid or not)
    # is converted, with bad bytes and characters UTF-8 lacks replaced:
    # reading UTF-16 bytes as UTF-8 would hide the password behind NULs.
    #
    # @param str [String]
    # @return [String]
    def utf8(str)
      return str if str.ascii_only? || (str.encoding == Encoding::UTF_8 && str.valid_encoding?)

      reread = str.encoding == Encoding::BINARY || (!str.valid_encoding? && str.encoding.ascii_compatible?)
      return String.new(str, encoding: Encoding::UTF_8).scrub if reread

      str.encode(Encoding::UTF_8, invalid: :replace, undef: :replace)
    end

    # Replace `form` in `text` only where it is a whole token: no ASCII word
    # character touches either edge, including a punctuation edge. A form
    # right after an {ESCAPE} counts as a whole token, and the escape is kept.
    #
    # @param text [String]
    # @param form [String] one form of the password.
    # @return [String]
    def redact_word(text, form)
      pattern = "(#{ESCAPE}|(?<!#{WORD_CHAR}))#{Regexp.escape(form)}(?!#{WORD_CHAR})"
      text.gsub(Regexp.new(pattern)) { "#{Regexp.last_match(1)}#{REDACTED}" }
    end

    # An exception as `Class: message`, redacted. Each part is redacted on its
    # own, so the join cannot raise on mixed encodings (a non-ASCII class name
    # next to, say, a Latin-1 message): a raise inside a rescue would make the
    # raw error the cause of the new one. For the same reason an exception
    # whose own `message` raises gives {FAILED}.
    #
    # @param error [Exception]
    # @return [String]
    def describe(error)
      "#{text(error.class)}: #{text(error.message)}"
    rescue StandardError
      FAILED
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

    # `url` cut before the first `/`, `?` or `#` after `scheme://`: the part
    # that holds the userinfo of a well-formed URL.
    #
    # @param url [String]
    # @return [String]
    def authority(url)
      start = url.index("://")
      return url unless start

      url[0...(url.index(%r{[/?#]}, start + 3) || url.length)]
    end

    # The raw value of each `password=` query parameter, which Rails and libpq
    # both accept in place of a `user:password@` pair. Every one, because
    # Rails keeps the last duplicate.
    #
    # @param url [String]
    # @return [Array<String>]
    def query_passwords(url)
      url.scan(/[?&]password=([^&#]+)/).flatten
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
