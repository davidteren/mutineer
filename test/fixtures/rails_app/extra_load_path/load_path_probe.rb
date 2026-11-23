# frozen_string_literal: true

# Found only through an extra load path (#491): no test-helper root holds it,
# so a test that requires it needs load_path: or -I under --daemon.
module LoadPathProbe
  # orders(:small): quantity 2 at 1000 cents.
  SMALL_SUBTOTAL_CENTS = 2000
end
