# frozen_string_literal: true

# #469 repro: heredoc lines and `%(...)` parts have no quotes of their own, so
# literal_mutation declines them. The `"..."` part still mutates.
class PromptText
  def prompt
    <<~PROMPT
      You are a helper.
      Answer briefly.
    PROMPT
  end

  def note(old)
    %(Saved (was: "#{old}"))
  end

  def greet(name)
    "Hello, #{name}"
  end
end
