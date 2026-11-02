# frozen_string_literal: true

require "minitest/mock"
require_relative "test_helper"
require "mutineer/redaction"
require "mutineer/coverage_map"
require "mutineer/cli"

# Error text can quote a credentialed DATABASE_URL in more than one shape:
# whole, `inspect` escaped, or cut short. None may show the password.
class RedactionTest < Minitest::Test
  def redact(text, url)
    Mutineer::Redaction.text(text, env: { "DATABASE_URL" => url })
  end

  def test_hides_a_password_that_inspect_escaped
    url = %(postgres://u:se"c\\ret@ho st/db)

    text = redact("URI::InvalidURIError: bad URI(is not URI?): #{url.inspect}", url)

    assert_includes text, "postgres://u:[REDACTED]@ho st/db"
    refute_includes text, "se\\\"c"
  end

  def test_hides_a_password_cut_short_after_a_quote
    url = %(postgres://u:sec"ret@host/db)

    text = redact(%(could not parse "postgres://u:sec"), url)

    assert_equal %(could not parse "postgres://u:[REDACTED]"), text
  end

  def test_hides_a_truncated_password_prefix
    url = "postgres://u:s3cretpass@host/db"

    text = redact("bad URI: postgres://u:s3cre...", url)

    assert_equal "bad URI: postgres://u:[REDACTED]...", text
  end

  def test_hides_a_truncated_password_after_an_escaped_username
    url = %(postgres://u"ser:s3cretpass@host/db)

    text = redact(%(bad URI: "postgres://u\\"ser:s3cre), url)

    assert_equal %(bad URI: "postgres://u\\"ser:[REDACTED]), text
  end

  def test_hides_a_password_that_starts_like_the_replacement
    url = "postgres://u:[REDACTED]tail@host/db"

    text = redact("bad URI: postgres://u:[REDACTED]tai", url)

    assert_equal "bad URI: postgres://u:[REDACTED]", text
  end

  def test_keeps_a_url_without_credentials_and_unrelated_text
    url = "postgres://u:s3cret@host/db"
    text = "PG::ConnectionBad: could not connect to http://host:5432/db"

    assert_equal text, redact(text, url)
    assert_equal text, redact(text, "")
  end

  def test_keeps_a_role_name_equal_to_the_password
    url = "postgres://postgres:postgres@localhost/db"

    text = redact(%(PG::ConnectionBad: FATAL: role "postgres" does not exist (#{url})), url)

    assert_equal %(PG::ConnectionBad: FATAL: role "postgres" does not exist ) +
                 "(postgres://postgres:[REDACTED]@localhost/db)", text
  end

  def test_keeps_words_that_contain_a_short_password
    text = %(ActiveRecord::NoDatabaseError: database "app" does not exist)

    assert_equal text, redact(text, "postgres://u:a@host/db")
  end

  def test_redacts_text_with_invalid_bytes
    url = "postgres://u:s3cret@ho st/db"

    text = redact((+"caf\xFF bad URI: #{url}").force_encoding(Encoding::UTF_8), url)

    assert_includes text, "[REDACTED]"
    refute_includes text, "s3cret"
  end

  def test_redacts_binary_text_with_a_non_ascii_password
    text = redact("auth failed: pässword".b, "postgres://u:pässword@h/db")

    assert_equal Encoding::UTF_8, text.encoding
    assert_includes text, "[REDACTED]"
    refute_includes text, "pässword"
  end

  def test_redacts_a_latin1_string_with_a_non_ascii_password
    text = redact("café pässword".encode("ISO-8859-1"), "postgres://u:pässword@h/db")

    assert_equal "café [REDACTED]", text
  end

  # Reading UTF-16 bytes as UTF-8 would put a NUL in every character, so the
  # password would never match and would print in clear.
  def test_redacts_utf16_text_with_an_invalid_byte
    text = redact("pw hunter2 x".encode("UTF-16LE").b.+("\xFF".b).force_encoding("UTF-16LE"),
                  "postgres://app:hunter2@db/app")

    assert_includes text, "[REDACTED]"
    refute_includes text, "hunter2"
  end

  def test_fails_closed_on_an_internal_error
    text = Mutineer::Redaction.stub(:password_forms, ->(_) { raise "boom" }) do
      redact("password s3cret", "postgres://u:s3cret@host/db")
    end

    assert_equal "[message hidden: redaction failed]", text
  end

  def test_hides_a_short_password_that_stands_alone
    assert_equal "pw [REDACTED] rejected", redact("pw a rejected", "postgres://u:a@host/db")
  end

  # An escape never swallows a copy of the form, and a form that starts with
  # punctuation is still hidden right after one.
  def test_an_escape_does_not_swallow_a_punctuation_password
    assert_equal "pw [REDACTED] rejected", redact("pw %41 rejected", "postgres://u:%41@host/db")
    refute redact("%41%41", "postgres://u:%41@host/db").start_with?("%41")
    { "!a" => ["\e[36m!a\e[0m", "\\n!a"], "!ab" => ["-p!ab"] }.each do |password, texts|
      texts.each { |text| refute_includes redact(text, "postgres://u:#{password}@host/db"), password, text }
    end
  end

  def test_short_punctuation_passwords_keep_other_tokens_readable
    { "!" => "word!word", "!a" => "word!aword", "a!" => "worda!word" }.each do |password, token|
      url = "postgres://u:#{password}@host/db"

      assert_equal token, redact(token, url)
      assert_equal "pw [REDACTED] rejected", redact("pw #{password} rejected", url)
    end
  end

  # A percent-encoded password that decodes to invalid UTF-8 must not make
  # every message the fail-closed placeholder.
  def test_handles_a_password_that_decodes_to_invalid_utf8
    url = "postgres://u:p%E4ss@host/db"

    assert_equal "auth [REDACTED] failed", redact((+"auth p\xE4ss failed").force_encoding(Encoding::UTF_8), url)
    assert_equal "unrelated text", redact("unrelated text", url)
  end

  def test_describe_survives_a_non_ascii_class_next_to_a_latin1_message
    url = "postgres://u:s3cret@ho st/db"
    klass = Class.new(StandardError) { def self.to_s = "Ärger288Error" }
    error = klass.new("café #{url}".encode("ISO-8859-1"))

    saved = ENV.fetch("DATABASE_URL", nil)
    ENV["DATABASE_URL"] = url
    text = Mutineer::Redaction.describe(error)

    assert_equal "Ärger288Error: café postgres://u:[REDACTED]@ho st/db", text
  ensure
    ENV["DATABASE_URL"] = saved
  end

  def test_describe_fails_closed_when_the_message_raises
    error = RuntimeError.new("x")
    def error.message = raise("boom")

    assert_equal Mutineer::Redaction::FAILED, Mutineer::Redaction.describe(error)
  end

  def test_hides_a_password_from_the_query_string
    assert_equal "conn failed for [REDACTED]",
                 redact("conn failed for hunter22", "postgres://u@h/db?sslmode=off&password=hunter22")
  end

  def test_hides_a_query_password_next_to_a_userinfo_password
    assert_equal "failed: [REDACTED] [REDACTED]",
                 redact("failed: dummypw realsecret", "postgres://u:dummypw@host/db?password=realsecret")
  end

  def test_hides_a_query_password_when_the_userinfo_password_equals_the_username
    assert_equal "x [REDACTED]", redact("x realsecret", "postgres://postgres:postgres@host/db?password=realsecret")
  end

  def test_hides_every_duplicate_query_password
    url = "postgres://u@h/db?password=changeme&password=Pr0dS3cret"

    assert_equal "x [REDACTED] [REDACTED]", redact("x changeme Pr0dS3cret", url)
  end

  def test_hides_the_password_when_a_query_value_holds_an_at_sign
    url = "postgres://app:s3cretpw@db:5432/app?application_name=ci@corp"

    assert_equal "FATAL: password [REDACTED] rejected", redact("FATAL: password s3cretpw rejected", url)
    assert_equal "x [REDACTED]", redact("x s3cr@tpw", "postgres://db:5432/app?password=s3cr@tpw")
  end

  def test_still_hides_a_bare_password_token
    assert_equal "password [REDACTED] rejected", redact("password s3cret rejected", "postgres://u:s3cret@host/db")
  end

  def test_hides_a_password_next_to_punctuation
    assert_equal %(key="[REDACTED]",), redact(%(key="s3cret",), "postgres://u:s3cret@host/db")
  end

  # A password is hidden even when an escape glues a word character to it:
  # %40, \u0041, \u{41}, \x41, \101, \n, an ANSI colour code, a -p flag.
  def test_hides_a_long_password_right_after_an_escape
    url = "postgres://u:s3cret@host/db"

    ["u%40s3cret", "\\u0041s3cret", "\\u{41}s3cret", "\\x41s3cret", "\\101s3cret", "\\ns3cret",
     "\e[1m\e[36ms3cret\e[0m", "\\e[36ms3cret", "\\033[36ms3cret", "\\x1b[36ms3cret", "\\u001b[36ms3cret", "[31ms3cret", "\e[Ks3cret", %(["mysql", "-ps3cret"]), "mysql -uapp -ps3cret prod"].each do |glued|
      text = redact("auth failed for #{glued}", url)

      refute_includes text, "s3cret", glued
      assert_includes text, "[REDACTED]", glued
    end
  end

  # #341 item 4: a password of word characters is hidden only as a whole
  # token, so it no longer blanks letters inside other words.
  def test_keeps_words_that_contain_a_long_word_password
    url = "postgres://u:test@host/db"

    assert_equal "/app/[REDACTED]/models/user_test.rb", redact("/app/test/models/user_test.rb", url)
    assert_equal "auth failed for xs3cret s3cret_x", redact("auth failed for xs3cret s3cret_x", "postgres://u:s3cret@host/db")
  end

  # A long form with a non-word character has no reliable token edge, so it
  # is still hidden inside other words.
  def test_hides_a_long_punctuation_password_inside_a_word
    assert_equal "x[REDACTED]y", redact("xp@ss!y", "postgres://u:p@ss!@host/db")
  end

  # #341 item 6: the URL password ends at the last `@` before a host with a
  # port, path or query, so the host and later text with an `@` stay readable.
  def test_url_password_stops_at_the_host
    {
      "postgres://u:p@ss@h/db and p@ss" => "postgres://u:[REDACTED]@h/db and p@ss",
      "postgres://u:my pass@h/db mail a@b.com" => "postgres://u:[REDACTED]@h/db mail a@b.com",
      %("postgres://u:p@ss@h:5432/db") => %("postgres://u:[REDACTED]@h:5432/db")
    }.each { |text, want| assert_equal want, redact(text, "") }
  end

  # When a malformed password may hold what looks like a host, hiding wins:
  # `pw@foo/bar qux` may be the whole password, so the match runs to the last
  # host. With no host after any `@`, it runs to the last `@`, as before.
  def test_url_password_fails_safe_when_the_host_is_ambiguous
    {
      "postgres://u:pw@foo/bar qux@h/db" => "postgres://u:[REDACTED]@h/db",
      "postgres://u:pa@ss word@h/db" => "postgres://u:[REDACTED]@h/db",
      "postgres://u:pw@h1/db, postgres://v:pw@h2/db" => "postgres://u:[REDACTED]@h2/db",
      "postgres://u:pw@x@" => "postgres://u:[REDACTED]@",
      "postgres://u:p@ss:word@host" => "postgres://u:[REDACTED]@host",
      %("postgres://u:p@ss/word@host") => %("postgres://u:[REDACTED]@host"),
      "postgres://u:p@ss:word@host failed" => "postgres://u:[REDACTED]@host failed",
      "postgres://u:a@b/c@d@h" => "postgres://u:[REDACTED]@h",
      "postgres://u:s3 cr@t@ho st/db" => "postgres://u:[REDACTED]@ho st/db"
    }.each { |text, want| assert_equal want, redact(text, "") }
  end

  # Known limit (#341): a password that holds an `@`, a host, a `/` and a
  # space shows the rest when the URL's own host has nothing after it, or has
  # an `@` in its path or query.
  def test_url_password_limit_is_pinned
    assert_equal "postgres://u:[REDACTED]@b/c d@h", redact("postgres://u:a@b/c d@h", "")
    assert_equal "postgres://u:[REDACTED]@h:1 x@db/app?n=ci@corp", redact("postgres://u:p@h:1 x@db/app?n=ci@corp", "")
  end

  def test_still_hides_a_password_that_only_partly_matches_the_username
    url = "postgres://postgres:postgres1@localhost/db"

    assert_equal %(role "postgres" said [REDACTED]), redact(%(role "postgres" said postgres1), url)
  end

  def test_hides_a_decoded_password_that_equals_the_username
    # Only an exact raw match skips: `a%62cd` decodes to `abcd`, the username,
    # but the raw values differ, so the decoded form is still hidden.
    assert_equal "user [REDACTED]", redact("user abcd", "postgres://abcd:a%62cd@host/db")
  end

  def test_cli_run_error_hides_the_password
    url = "postgres://u:s3cret@ho st/db"
    saved = ENV.fetch("DATABASE_URL", nil)
    ENV["DATABASE_URL"] = url
    config = Mutineer::Config.new
    config.sources = ["a.rb"]
    exit_error = nil

    _, err = capture_io do
      Mutineer::CLI.stub(:validate!, nil) do
        Mutineer::CLI.stub(:execute, ->(_) { raise ArgumentError, "bad #{url}" }) do
          exit_error = assert_raises(SystemExit) { Mutineer::CLI.run(config) }
        end
      end
    end

    assert_equal 2, exit_error.status
    assert_includes err, "[REDACTED]"
    refute_includes err, "s3cret"
  ensure
    ENV["DATABASE_URL"] = saved
  end

  def test_coverage_warning_hides_the_password
    url = "postgres://u:s3cret@ho st/db"
    map = Mutineer::CoverageMap.new(source_paths: [], test_paths: [])
    saved = ENV.fetch("DATABASE_URL", nil)
    ENV["DATABASE_URL"] = url

    _, err = capture_io { map.send(:fail_test, "test/a_test.rb", "fork capture failed: bad URI: #{url.inspect}") }

    assert_includes err, "coverage skipped"
    assert_includes err, "[REDACTED]"
    refute_includes err, "s3cret"
  ensure
    ENV["DATABASE_URL"] = saved
  end
end
