# frozen_string_literal: true

# Shared by BoardsController. No paired test at the conventional path; the
# controller test covers `scoped_board_id` through the include (#382).
module BoardScoped
  def scoped_board_id(id)
    id + 10
  end
end
