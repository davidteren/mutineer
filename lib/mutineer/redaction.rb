# frozen_string_literal: true

require "uri"

module Mutineer
  # Hides database credentials in text bound for a terminal: an error reply,
  # a log line, a warning. Rails parses DATABASE_URL itself, so an error about
  # a malformed one can quote the whole URL.
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

    module_function

    # Hide the password in any URL, and the DATABASE_URL password wherever it
    # appears: whole, percent-decoded, `inspect` escaped, or cut short after
    # its `scheme://user:` prefix.
    #
    # @param text [#to_s]
    # @param env [Hash{String => String}] where DATABASE_URL is read.
    # @return [String]
    def text(text, env: ENV)
      out = text.to_s
      head, raw = database_url_parts(env["DATABASE_URL"].to_s)
      secrets = raw ? password_forms(raw) : []
      # Prefixes first, on the caller's text, so no replacement made here can
      # be mistaken for part of a password.
      [head, head&.inspect&.[](1...-1)].compact.uniq.each do |prefix|
        out = secrets.reduce(out) { |acc, secret| redact_prefixes(acc, prefix, secret) }
      end
      out = out.gsub(URL_PASSWORD) { "#{Regexp.last_match(1)}:#{REDACTED}@" }
      secrets.reduce(out) { |acc, secret| acc.gsub(secret, REDACTED) }
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
        URI.decode_www_form_component(raw.gsub("+", "%2B"))
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
