# frozen_string_literal: true

# Like Zeitwerk with eager load off: booting only registers the constants.
# Each class body runs the first time something names the constant (#493).
autoload :LanguageRecord, File.expand_path("lib/language_record", __dir__)
autoload :LanguageProduct, File.expand_path("lib/language_product", __dir__)
