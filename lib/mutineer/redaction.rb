# frozen_string_literal: true

require "uri"

module Mutineer
  # Hides database credentials in text bound for a terminal: an error reply,
  # a log line, a warning. Rails parses DATABASE_URL itself, so an error about
  # a malformed one can quote the whole URL. Outside a URL a password form
  # made only of word characters is hidden only as a whole token, so it cannot
  # blank letters inside other words (#341). A password that exactly equals the
  # username, the host, or the database name is left visible outside a URL,
  # because the redacted URL already shows that word (`role "postgres"`,
  # `localhost`, `database "app"`). So is a one-character password, and a
  # password that is one of {COMMON_WORDS}: those words are ordinary text in
  # errors and paths. The password inside a URL, and the value of a
  # `password=` query parameter, stays hidden in every one of those cases.
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
    # `u:pw@h/x and y@h2/db` the text up to `h2` is hidden. The matcher
    # contract, pinned by the redaction test, still shows the tail of one
    # malformed password: it holds an `@`, a host, a `/`, `:`, `?` or `#`,
    # and a space (`a@b/c d`), in a URL whose own host has no port, path or
    # query, or has an `@` in them (`?n=ci@corp`). A DATABASE_URL password
    # is still hidden by the prefix and blanket passes.
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
    # `\n`, an ANSI code such as the colour Rails logs put on a span (raw,
    # escaped as `\e`, `\033`, `\x1b` or `\u001b`, or with its ESC byte
    # stripped), or a `-p` flag after a space, quote, bracket, comma or `=`
    # (`mysql -ps3cret`, `["-ps3cret"]`). A form right after one is still a
    # whole token.
    ESCAPE = /%\h{2}|\\x\h{2}|\\u(?:\h{4}|\{\h+\})|\\[0-7]{1,3}|(?:\e|\\(?:e|033|x1[bB]|u001[bB]))?\[[0-9;]*[A-Za-z]|\\[a-z]|(?<![^\s"'(\[,=])-p/.source
    # Passwords left visible as bare words (#341). Each one is also ordinary
    # text in a backtrace, a log line, or a database error (`password
    # authentication failed`, `/app/test/`). Hiding the word makes that line
    # unreadable. Local and CI URLs often use one of these; a production
    # password is usually not a dictionary word. The URL and `password=`
    # passes still hide the value. Matched exactly, in this case: `Password`
    # is still hidden.
    COMMON_WORDS = %w[
      password passwd secret test admin root guest user username
      database localhost host port name token key login credential
      postgres mysql redis default welcome
    ].freeze
    # Where a `password=` query value ends in a message: the next query
    # delimiter, or the quote or bracket that closed the URL.
    QUERY_VALUE_END = /(?=&|#|\s|"|'|`|\)|\]|\}|,|\\|\z)/

    module_function

    # Extra DATABASE_URL values, besides `env` in {text}. The CLI and the
    # daemon set this from dotenv files so a password the app loads itself
    # is still hidden (#341). Empty unless a caller sets it.
    #
    # @return [Array<String>]
    def extra_urls
      @extra_urls || []
    end

    # Replace {extra_urls}. Blank values are dropped. Frozen, so a caller
    # cannot change the list the redaction thread is reading.
    #
    # @param urls [Array<String>]
    # @return [Array<String>]
    def extra_urls=(urls)
      @extra_urls = Array(urls).map { |url| utf8(url.to_s) }.uniq.reject(&:empty?).freeze
    end

    # Hide the password in any URL, and each DATABASE_URL password (from its
    # `user:password@` pair and from its `password=` query parameter) wherever
    # it appears: whole, percent-decoded, `inspect` escaped, or cut short after
    # its `scheme://user:` prefix. `env` supplies one URL. {extra_urls} and
    # `urls` supply the rest (a dotenv file, or a URL the app set itself).
    # Outside a URL a form of word characters, or of {SHORT_FORM} characters or
    # fewer, is hidden only as a whole token; a longer form with another
    # character is hidden anywhere. A raw password that equals the username,
    # the host, or the database name, a form of one character, and a form in
    # {COMMON_WORDS} are left visible outside a URL. The `password=` value
    # itself is still replaced. Never raises: text in any encoding comes back
    # as UTF-8, and an internal error returns {FAILED}.
    #
    # @param text [#to_s]
    # @param env [Hash{String => String}] where DATABASE_URL is read.
    # @param urls [Array<String>] more credential URLs, besides {extra_urls}.
    # @return [String]
    def text(text, env: ENV, urls: [])
      out = utf8(text.to_s)
      sources = source_urls(env, urls)
      # Prefixes first, on the caller's text, so no replacement made here can
      # be mistaken for part of a password. Two readings of each userinfo: up
      # to the last `@` (a malformed password may hold any character) and up
      # to the last `@` before the path (a query value may hold an `@`). Both
      # are hidden: hiding too much is safe.
      sources.each do |url|
        credential_parts(url).each do |head, raw|
          forms = password_forms(raw)
          [head, head.inspect[1...-1]].uniq.each do |prefix|
            out = forms.reduce(out) { |acc, secret| redact_prefixes(acc, prefix, secret) }
          end
        end
      end
      out = out.gsub(URL_PASSWORD) { "#{Regexp.last_match(1)}:#{REDACTED}@" }
      secrets = []
      sources.each do |url|
        host, database = url_labels(url).values_at(1, 2)
        credential_parts(url).each do |head, raw|
          # The username is not a secret: the redacted URL prints it. The skip
          # needs an exact raw match. A password that only shares a form or a
          # prefix with the username is a separate secret and stays hidden.
          user = head[(head.index("://") + 3)...-1]
          password_forms(raw).each { |form| out = redact_query_value(out, form) }
          next if outside_url_visible?(raw, user: user, host: host, database: database)

          secrets.concat(password_forms(raw))
        end
        # A `password=` value is always replaced in the parameter. Rails
        # prefers it over the userinfo password. The bare word follows the
        # same outside-URL rules as a userinfo password.
        query_passwords(url).each do |raw|
          password_forms(raw).each { |form| out = redact_query_value(out, form) }
          next if outside_url_visible?(raw, user: nil, host: host, database: database)

          secrets.concat(password_forms(raw))
        end
      end
      secrets.uniq.sort_by { |form| -form.length }.reduce(out) do |acc, secret|
        next acc unless blanket_form?(secret)

        whole_token = secret.length <= SHORT_FORM || secret.match?(/\A#{WORD_CHAR}+\z/)
        whole_token ? redact_word(acc, secret) : acc.gsub(secret, REDACTED)
      end
    rescue StandardError
      FAILED
    end

    # Every DATABASE_URL this call should treat as a credential. Blank values
    # are dropped. The order does not matter: each password is applied.
    #
    # @param env [Hash{String => String}]
    # @param urls [Array<String>]
    # @return [Array<String>]
    def source_urls(env, urls)
      ([env["DATABASE_URL"], *extra_urls, *urls]).map { |url| utf8(url.to_s) }.uniq.reject(&:empty?)
    end

    # The userinfo readings of `url`. See {text}.
    #
    # @param url [String]
    # @return [Array<Array(String, String)>]
    def credential_parts(url)
      [database_url_parts(url), database_url_parts(authority(url))].compact.uniq
    end

    # Username, host, and database name of `url`, or nils when that part is
    # missing. The host drops a trailing `:port`. The database name is the
    # path before `?` or `#`. An `@` in the query or the path is not the
    # userinfo separator: the host is read from the authority, the substring
    # before the first `/`, `?`, or `#`.
    #
    # @param url [String]
    # @return [Array(String, String, String)] username, host, and database name; a missing part is nil.
    def url_labels(url)
      start = url.index("://")
      return [nil, nil, nil] unless start

      body = url[(start + 3)..]
      cut = body.index(%r{[/?#]})
      authority = cut ? body[0...cut] : body
      path = cut && body[cut] == "/" ? body[(cut + 1)..].split(%r{[?#]}, 2).first : nil
      database = path unless path.nil? || path.empty?
      at = authority.rindex("@")
      if at
        userinfo = authority[0...at]
        hostport = authority[(at + 1)..]
        colon = userinfo.index(":")
        user = colon ? userinfo[0...colon] : userinfo
      else
        user = nil
        hostport = authority
      end
      host = hostport.sub(/:\d+\z/, "")
      host = nil if host.empty?
      [user, host, database]
    end

    # Bytes at the end of `buffer` that must stay buffered. A password form
    # that contains a newline can span reads. Zero when no form contains a
    # newline, which is the usual URL. The held bytes are a prefix of such a
    # form, not a finished copy.
    #
    # @param buffer [String]
    # @return [Integer]
    def newline_hold(buffer)
      forms = newline_forms
      return 0 if forms.empty?

      hold = 0
      forms.each do |form|
        limit = form.b.bytesize - 1
        next if limit < 1

        size = [limit, buffer.bytesize].min
        size.downto(1) do |n|
          next unless buffer.byteslice(-n, n) == form.b.byteslice(0, n)

          hold = n if n > hold
          break
        end
      end
      hold
    end

    # The prefix of `buffer` that can be redacted now, and the rest to keep.
    # Unless `flush`, the prefix ends on a newline and does not end inside a
    # password that itself contains a newline.
    #
    # @param buffer [String]
    # @param flush [Boolean] emit everything, including a partial tail.
    # @return [Array(String, String)]
    def take_redactable(buffer, flush:)
      buffer = buffer.b
      hold = flush ? 0 : newline_hold(buffer)
      usable_end = buffer.bytesize - hold
      usable = buffer.byteslice(0, usable_end) || +"".b
      if flush
        [usable, +"".b]
      else
        cut = usable.rindex("\n".b)
        return [+"".b, buffer] unless cut

        ready = usable.byteslice(0, cut + 1)
        rest = +"".b
        rest << usable.byteslice(cut + 1, usable.bytesize - cut - 1) if cut + 1 < usable.bytesize
        rest << buffer.byteslice(usable_end, hold) if hold.positive?
        [ready, rest]
      end
    end

    # Password forms that contain a newline. Cached for the current
    # DATABASE_URL and {extra_urls}. Empty for an ordinary URL.
    #
    # @return [Array<String>]
    def newline_forms
      marker = ENV["DATABASE_URL"].to_s
      urls = extra_urls
      return @newline_forms if @newline_marker == marker && @newline_urls.equal?(urls)

      @newline_marker = marker.dup.freeze
      @newline_urls = urls
      forms = []
      source_urls(ENV, []).each do |url|
        credential_parts(url).each do |_head, raw|
          password_forms(raw).each { |form| forms << form if form.include?("\n") }
        end
        query_passwords(url).each do |raw|
          password_forms(raw).each { |form| forms << form if form.include?("\n") }
        end
      end
      @newline_forms = forms.uniq.freeze
    end

    # True when `raw` must not be blanked outside a URL or a `password=`
    # parameter (#341). Exact match only, same as the username rule.
    #
    # @param raw [String]
    # @param user [String, nil]
    # @param host [String, nil]
    # @param database [String, nil]
    # @return [Boolean]
    def outside_url_visible?(raw, user:, host:, database:)
      return true if raw.nil? || raw.empty? || raw.length <= 1
      return true if COMMON_WORDS.include?(raw)

      raw == user || raw == host || raw == database
    end

    # True when this password form is hidden outside a URL. A one-character
    # form and a {COMMON_WORDS} form are not: they are ordinary text.
    #
    # @param form [String]
    # @return [Boolean]
    def blanket_form?(form)
      return false if form.nil? || form.empty? || form.length <= 1
      return false if COMMON_WORDS.include?(form)

      true
    end

    # Replace one `password=` query value and keep the parameter name. `form`
    # must be the whole value, so a one-character password does not eat the
    # start of a longer value.
    #
    # @param text [String]
    # @param form [String]
    # @return [String]
    def redact_query_value(text, form)
      return text if form.nil? || form.empty?

      text.gsub(/([?&]password=)#{Regexp.escape(form)}#{QUERY_VALUE_END}/) do
        "#{Regexp.last_match(1)}#{REDACTED}"
      end
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
    # right after an {ESCAPE} also counts as a whole token, and the escape is
    # kept. An escape may not start where a copy of the form starts, so it
    # cannot swallow that copy (`%41%41` with password `%41`).
    #
    # @param text [String]
    # @param form [String] one form of the password.
    # @return [String]
    def redact_word(text, form)
      quoted = Regexp.escape(form)
      pattern = "((?!#{quoted})(?:#{ESCAPE})|(?<!#{WORD_CHAR}))#{quoted}(?!#{WORD_CHAR})"
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
