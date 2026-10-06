# frozen_string_literal: true

WrappedPoint = (Data.define(:x) do
  def m
    x * 2
  end
end)

WrappedOrA ||= Data.define(:x) do
  def m
    x * 2
  end
end
