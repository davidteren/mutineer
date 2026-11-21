# frozen_string_literal: true

# Stands in for Rails eager load: LanguageProduct's class body calls
# language_field before any mutant (#493).
require_relative "lib/language_record"
require_relative "lib/language_product"
