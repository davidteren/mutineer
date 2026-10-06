# frozen_string_literal: true

# Included by two classes, so one method is two tests.
module MatrixSharedAcctTests
  def test_shared_deposit
    assert_equal 15, MatrixAcct.new(10).deposit(5)
  end
end
