# frozen_string_literal: true

# #528: like an app that names a class at boot. PinnedGridPoint then holds
# GridPoint's class before any mutant is applied.
Rails.application.config.to_prepare { PinnedGridPoint }
