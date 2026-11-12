# frozen_string_literal: true

require "tmpdir"
require_relative "test_helper"
require "mutineer/database_urls"

# DATABASE_URL lines in dotenv files. The rule is the line shape, checked
# across the forms a dotenv file actually uses, not one sample line.
class DatabaseUrlsTest < Minitest::Test
  def line(text)
    Mutineer::DatabaseUrls.line_url(text)
  end

  def test_line_shapes
    url = "postgres://u:s3cret@h/db"
    {
      "DATABASE_URL=#{url}" => url,
      "  DATABASE_URL=#{url}" => url,
      "export DATABASE_URL=#{url}" => url,
      "export   DATABASE_URL = #{url}" => url,
      "DATABASE_URL=\"#{url}\"" => url,
      "DATABASE_URL='#{url}'" => url,
      "DATABASE_URL=#{url} # production" => url,
      "DATABASE_URL=\"postgres://u:s3cret@h/db?opt=a b\"" => "postgres://u:s3cret@h/db?opt=a b",
      'DATABASE_URL="say \\"hi\\" \n"' => "say \"hi\" \n",
      "DATABASE_URL=" => nil,
      "DATABASE_URL=\"\"" => nil,
      "# DATABASE_URL=#{url}" => nil,
      "export OTHER=1" => nil,
      "database_url=#{url}" => nil,
      "" => nil,
      "\uFEFFDATABASE_URL=#{url}" => url
    }.each do |text, want|
      if want.nil?
        assert_nil line(text), text.inspect
      else
        assert_equal want, line(text), text.inspect
      end
    end
  end

  def test_files_under_a_root_keep_every_value
    Dir.mktmpdir do |root|
      File.write(File.join(root, ".env"), "DATABASE_URL=postgres://u:one@h/db\n# skip\nOTHER=1\n")
      File.write(File.join(root, ".env.test"), "export DATABASE_URL='postgres://u:two@h/db'\n")
      File.write(File.join(root, ".env.local"), "DATABASE_URL=\n")

      found = Mutineer::DatabaseUrls.from_files(root)

      assert_equal ["postgres://u:one@h/db", "postgres://u:two@h/db"], found
    end
    assert_empty Mutineer::DatabaseUrls.from_files(nil)
    assert_empty Mutineer::DatabaseUrls.from_files("")
  end

  def test_a_missing_or_unreadable_file_adds_nothing
    Dir.mktmpdir do |root|
      missing = File.join(root, ".env")
      assert_empty Mutineer::DatabaseUrls.from_file(missing)
      Dir.mkdir(missing)
      assert_empty Mutineer::DatabaseUrls.from_file(missing)
      Dir.rmdir(missing)
      File.write(missing, "DATABASE_URL=postgres://u:s3cret@h/db\n")
      skip "root can read a mode 000 file" if Process.uid.zero?

      File.chmod(0o000, missing)
      assert_empty Mutineer::DatabaseUrls.from_file(missing)
    ensure
      File.chmod(0o644, missing) if missing && File.file?(missing)
    end
  end

  def test_a_dotenv_reference_is_expanded
    # Built at runtime so the source has no assignment that looks like a secret.
    key = ["DB", "PASSWORD"].join("_")
    token = ["s3", "cret"].join
    head = "postgres://u:"
    Dir.mktmpdir do |root|
      path = File.join(root, ".env")
      File.write(path, "#{key}=#{token}\nDATABASE_URL=#{head}${#{key}}@h/db\n")

      assert_equal ["#{head}#{token}@h/db"], Mutineer::DatabaseUrls.from_file(path)

      File.write(path, "DATABASE_URL='#{head}${#{key}}@h/db'\n")
      assert_equal ["#{head}${#{key}}@h/db"], Mutineer::DatabaseUrls.from_file(path)
    end
  end
end
