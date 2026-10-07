# frozen_string_literal: true

# #222: a --require file that writes a row while the app boots, into a table with
# no fixture (so `fixtures :all` never replaces it).
connection = ActiveRecord::Base.connection
connection.create_table(:seeded_rows, force: true) { |t| t.string :name }
connection.execute("INSERT INTO seeded_rows (name) VALUES ('from boot')")
