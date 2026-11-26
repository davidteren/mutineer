# frozen_string_literal: true

case ENV.fetch("MUTINEER_HELPER_SEED_MODE", "or")
when "assign"
  ENV["SEED"] = "99"
when "or"
  ENV["SEED"] ||= "99"
when "clear"
  ENV.delete("SEED")
end

$mutineer_helper_seed_ready = false
