# frozen_string_literal: true

require_relative "test_helper"
require "mutineer/redaction"
require "mutineer/coverage_map"

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
