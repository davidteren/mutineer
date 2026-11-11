# frozen_string_literal: true

require_relative "concerns/board_scoped"

class BoardsController
  include BoardScoped

  def show(id)
    scoped_board_id(id)
  end
end
