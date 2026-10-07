# frozen_string_literal: true

# #220: a --require file that calls a source method at load.
TAX_SETUP = TaxTable.rate(3)
