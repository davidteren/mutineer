# frozen_string_literal: true

# #187: like an app that registers a catalog at boot. PriceList's class body
# runs while the app boots, not in any test.
Rails.application.config.to_prepare { PriceList::ALL }
