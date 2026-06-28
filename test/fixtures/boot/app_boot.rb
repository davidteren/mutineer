# frozen_string_literal: true

# Stands in for config/environment: the file the parent requires ONCE to "boot"
# the app. Booting loads the app's classes (here, Widget) — without Rails or a DB
# — so forked children inherit them. Mutineer must NOT separately require widget.
APP_BOOTED = true
require_relative "widget"
