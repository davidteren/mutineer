# frozen_string_literal: true

# #279 fixture. `shout` reads a file beside this source through `__dir__`. The
# `+ 0` mutant is equivalent and must survive under both strategies. When
# redefine loaded the method from the temp dir, the read raised ENOENT and every
# mutant was falsely killed.
class PathRelative
  def shout(n)
    File.read(File.join(__dir__, "path_relative.txt")).strip * (n + 0)
  end
end
