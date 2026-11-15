# frozen_string_literal: true

# #339 fixture. Each method resolves a path from this file. The `+ 0` mutant is
# equivalent and must survive under redefine when this directory is read-only.
# The `*` mutant must be killed by the test that calls that method.
class PathAnchor
  def via_dir(n)
    File.read(File.join(__dir__, "anchor.txt")).strip * (n + 0)
  end

  def via_file(n)
    dir = File.dirname(File.expand_path(__FILE__))
    File.read(File.join(dir, "anchor.txt")).strip * (n + 0)
  end

  def via_require(n)
    require_relative "sibling"
    PathAnchorSibling::MARK * (n + 0)
  end
end
