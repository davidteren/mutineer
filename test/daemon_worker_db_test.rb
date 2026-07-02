# frozen_string_literal: true

require_relative "test_helper"
require "mutineer/daemon_client"

# #26/U5 — per-worker DB routing, proven end-to-end against the bundled fixture app.
# Drives the daemon directly (via DaemonClient) so it can exercise MORE THAN ONE
# worker slot serially: for each of worker 0 and worker 1, the unmutated source
# SURVIVES and an arithmetic mutant is KILLED. That proves after_fork(worker) connects
# each isolated `storage/test-<worker>.sqlite3`, loads its schema, and lets the
# transactional fixtures repopulate it — the serial-correctness half of #26 (the
# concurrent `--jobs N == --jobs 1` gate is U6).
class DaemonWorkerDbTest < Minitest::Test
  APP   = File.expand_path("fixtures/rails_app", __dir__)
  ORDER = File.join(APP, "app/models/order.rb")
  TEST  = File.join(APP, "test/models/order_test.rb")

  def boot_config
    {
      project_root: APP,
      boot: File.join(APP, "config/environment"),
      load_paths: [File.join(APP, "test")],
      source_dirs: [File.join(APP, "app/models")],
      framework: "minitest",
      rails: true,
      schema: File.join(APP, "db/schema.rb")
    }
  end

  def with_client
    client = Mutineer::DaemonClient.new(boot: boot_config, app_root: APP).start
    yield client
  ensure
    client&.quit
  end

  def verdict(client, id:, code:, worker:)
    client.request(id: id, worker: worker, timeout: 60,
                   payload: { "code" => code, "source_file" => ORDER },
                   tests: [TEST])
  end

  def test_verdicts_are_correct_across_distinct_worker_dbs
    original = File.read(ORDER)
    # `*` -> `+`: subtotal 2*1000 becomes 1002, so the strong suite's
    # `assert_equal 2000` fails -> the mutant is killed. Deterministic.
    mutant = original.sub("quantity * unit_price_cents", "quantity + unit_price_cents")
    refute_equal original, mutant, "the substitution must actually change the source"

    with_client do |client|
      [0, 1].each do |w|
        assert_equal "survived", verdict(client, id: 10 + w, code: original, worker: w),
                     "unmutated source survives on worker #{w}'s DB"
        assert_equal "killed", verdict(client, id: 20 + w, code: mutant, worker: w),
                     "arithmetic mutant is killed on worker #{w}'s DB"
      end
    end
  end
end
