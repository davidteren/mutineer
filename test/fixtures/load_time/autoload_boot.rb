# frozen_string_literal: true

# Like Zeitwerk: booting only registers Catalog. Its class body runs the first
# time something names the constant.
autoload :Catalog, File.expand_path("lib/catalog", __dir__)
