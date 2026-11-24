# frozen_string_literal: true

# Calls the macro in its class body, so the blocks are stored when this class
# loads (#493).
class LanguageProduct < LanguageRecord
  language_field

  def label
    "product"
  end
end
