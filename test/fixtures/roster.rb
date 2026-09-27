# frozen_string_literal: true

class Roster
  Member = Struct.new(:name, :active)

  def initialize(members)
    @members = members
  end

  def active_names
    @members.select(&:active).map(&:name).sort
  end
end
