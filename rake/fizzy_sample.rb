# frozen_string_literal: true

require "json"
require "yaml"
require "fileutils"
require "open3"
require "rbconfig"
require_relative "../lib/mutineer"

# The pre-release check on a real Rails 8 app (#402). `rake fizzy:sample` runs
# this checkout's Mutineer on a pinned Fizzy commit and a few files, then
# compares the JSON summary counts and survivor ids with the ones stored in
# fizzy_sample.json. `rake fizzy:record` stores the last run's counts. A person
# runs both by hand; nothing schedules them.
#
# The comparison and recording functions take parsed JSON and touch no disk,
# so the zero-dependency suite tests them without Fizzy.
module FizzySample
  # The checkout root: its bin/mutineer runs, and its HEAD is recorded.
  ROOT = File.expand_path("..", __dir__)

  # The stored pin (repo, commit, files) and the recorded counts.
  DATA = File.join(__dir__, "fizzy_sample.json")

  # The clone's .mutineer.yml. No `require:` key: Fizzy's own boot file works
  # around reload bugs, and this check must see those bugs as errored mutants.
  CONFIG = { "rails" => true, "daemon" => true, "shared_databases" => ["cable"] }.freeze

  # Integer hashes in `summary`, compared by inner key so a count that moves
  # between operators fails even when the total stays the same.
  NESTED = %w[declined_by_operator legacy_id_matches].freeze

  # Lines of run.log printed when a run fails.
  LOG_TAIL = 40

  # A setup failure or a refused record. The Rake task aborts with its message.
  class Error < StandardError; end

  class << self
    # Run the sample and compare it with the stored counts.
    #
    # @return [void]
    # @raise [Error] on a setup failure or any difference.
    def sample!
      data = JSON.parse(File.read(DATA))
      cache = cache_dir
      with_lock(cache) do
        report_path, meta_path, log = paths(cache)
        head = clean_head!(git_head) # before the run, so the meta names the code that produced the counts
        clone = prepare!(data, cache, [report_path, meta_path])
        ruby = check_ruby!(clone)
        step("database")
        sh!(clone, "bin/rails", "db:test:prepare")
        step("run (log: #{log})")
        status = run!(clone, data["files"], report_path, log)
        raise Error, "Mutineer did not complete (#{status ? "exit #{status}" : "killed by a signal"}).\n#{log_tail(log)}" unless completed?(status, report_path)

        File.write(meta_path, JSON.pretty_generate(meta(data, head, ruby)) + "\n")
        step("compare")
        report = JSON.parse(File.read(report_path))
        failures, notes = compare(data, report)
        notes.each { |line| puts line }
        raise Error, ([*failures, *no_verdict_lines(report), "Explain each difference by its merged pull request, then run `bundle exec rake fizzy:record`.", "Run log: #{log}"].join("\n") + "\n#{log_tail(log)}") if failures.any?

        rec = data["recorded"]
        puts "Fizzy sample matches the counts recorded with #{rec["mutineer_version"]} at #{rec["mutineer_sha"]}"
      end
    end

    # Store the last run's counts and survivor ids in {DATA}.
    #
    # @return [void]
    # @raise [Error] when no report exists or {recorded} refuses it.
    def record!
      data = JSON.parse(File.read(DATA))
      cache = cache_dir
      with_lock(cache) do
        report_path, meta_path, = paths(cache)
        raise Error, "No report in #{cache}. Run `bundle exec rake fizzy:sample` first." unless File.file?(report_path) && File.file?(meta_path)

        updated = recorded(data, JSON.parse(File.read(report_path)), JSON.parse(File.read(meta_path)), git_head)
        File.write(DATA, JSON.pretty_generate(updated) + "\n")
        puts "Recorded the Fizzy sample counts in #{DATA}"
      end
    end

    # The cache folder, outside every checkout so worktrees share the clone and gems.
    #
    # @param env [Hash{String => String}]
    # @return [String]
    def cache_dir(env = ENV)
      base = env["XDG_CACHE_HOME"].to_s
      base = File.join(Dir.home, ".cache") if base.empty?
      File.join(base, "mutineer", "fizzy-sample")
    end

    # Every compared count: integer `summary` keys, plus `outer.inner` for {NESTED}.
    #
    # @param summary [Hash] the report's `summary`.
    # @return [Hash{String => Integer}]
    def counts(summary)
      summary.each_with_object({}) do |(key, value), out|
        if value.is_a?(Integer)
          out[key] = value
        elsif NESTED.include?(key) && value.is_a?(Hash)
          value.each { |inner, n| out["#{key}.#{inner}"] = n if n.is_a?(Integer) }
        end
      end
    end

    # Compare a report with the stored data.
    #
    # @param data [Hash] parsed {DATA}.
    # @param report [Hash] parsed `--format json` report.
    # @return [Array(Array<String>, Array<String>)] failure lines (empty on a
    #   match) and notes that do not fail.
    def compare(data, report)
      now = counts(report["summary"])
      ids = report["survivors"].map { |s| s["id"] }.sort
      was = data["counts"]
      if was.nil?
        return [["No counts recorded. This run: #{JSON.generate(now)}, " \
                 "#{ids.size} survivors. Review it, then run `bundle exec rake fizzy:record`."], []]
      end

      failures = was.filter_map do |key, old|
        next "#{key}: missing from the report" unless now.key?(key)

        "#{key}: #{old} -> #{now[key]}" unless now[key] == old
      end
      failures << "errored: #{now["errored"]} (must be 0)" if now["errored"].to_i.positive? && was["errored"] == now["errored"]
      gone = data["survivors"] - ids
      added = ids - data["survivors"]
      failures << "survivors new: #{added}" if added.any?
      failures << "survivors gone: #{gone}" if gone.any?
      notes = (now.keys - was.keys).map { |key| "note: new report key #{key} = #{now[key]} (not compared)" }
      [failures, notes]
    end

    # One `file:line status details` line per `no_verdict` entry.
    #
    # @param report [Hash]
    # @return [Array<String>]
    def no_verdict_lines(report)
      report.fetch("no_verdict", []).map { |e| "#{e["file"]}:#{e["line"]} #{e["status"]} #{e["details"]}" }
    end

    # The new {DATA} content for a finished run.
    #
    # @param data [Hash] parsed {DATA}.
    # @param report [Hash] parsed report.
    # @param meta [Hash] parsed report-meta.json from the same run.
    # @param head [String] this checkout's `git rev-parse HEAD`.
    # @return [Hash]
    # @raise [Error] when the run errored or belongs to another pin or commit.
    def recorded(data, report, meta, head)
      now = counts(report["summary"])
      raise Error, "Refusing to record: errored is #{now["errored"]}, not 0." if now["errored"].to_i.positive?
      raise Error, "Refusing to record: no_verdict is #{now["no_verdict"]}, not 0 (timeouts or uncapturable mutants)." if now["no_verdict"].to_i.positive?
      raise Error, "Refusing to record: the report ran a different Fizzy commit or file list." unless meta.values_at("commit", "files") == data.values_at("commit", "files")
      raise Error, "Refusing to record: the report ran uncommitted changes (#{meta["mutineer_sha"]}). Commit, then run fizzy:sample again." if meta["mutineer_sha"].to_s.end_with?("-dirty")
      raise Error, "Refusing to record: the report ran mutineer #{meta["mutineer_sha"]}, but HEAD is #{head}." unless meta["mutineer_sha"] == head

      data.merge(
        "recorded" => { "mutineer_version" => Mutineer::VERSION, "mutineer_sha" => head,
                        "app_ruby" => meta["app_ruby"], "date" => Time.now.utc.strftime("%Y-%m-%d") },
        "counts" => now,
        "survivors" => report["survivors"].map { |s| s["id"] }.sort
      )
    end

    # What report-meta.json stores, so {recorded} can bind the report to its run.
    #
    # @param data [Hash] parsed {DATA}.
    # @param head [String] mutineer commit that ran.
    # @param ruby [String] the app-side Ruby version.
    # @return [Hash]
    def meta(data, head, ruby)
      { "commit" => data["commit"], "files" => data["files"], "mutineer_sha" => head, "app_ruby" => ruby }
    end

    # True when Mutineer finished: exit 0 (pass) or 1 (gate failed) and a report.
    # Exit 2 is a usage or config error.
    #
    # @param status [Integer, nil]
    # @param report_path [String]
    # @return [Boolean]
    def completed?(status, report_path)
      [0, 1].include?(status) && File.file?(report_path)
    end

    # This checkout's bin/mutineer under the running Ruby's absolute path, so
    # Fizzy's .ruby-version cannot pick the tool's Ruby.
    #
    # @param files [Array<String>]
    # @param report_path [String]
    # @return [Array<String>]
    def run_command(files, report_path)
      [RbConfig.ruby, File.join(ROOT, "bin", "mutineer"), "run", *files,
       "--daemon", "--jobs", "4", "--format", "json", "--output", report_path]
    end

    # The environment for every child in the clone: no tool bundle, Fizzy's
    # Ruby pinned for rbenv and asdf, SQLite, and no CI or SEED.
    #
    # @param ruby [String] Fizzy's .ruby-version.
    # @param base [Hash{String => String}] the environment to start from.
    # @return [Hash{String => String}]
    def child_env(ruby, base = unbundled_env)
      env = base.dup
      env["RBENV_VERSION"] = ruby
      env["ASDF_RUBY_VERSION"] = ruby
      env["RAILS_ENV"] = "test"
      env["SAAS"] = "false"
      env["DATABASE_ADAPTER"] = "sqlite"
      # CI makes Fizzy eager-load, which hides lazy-load bugs. SEED would replace Mutineer's pinned seed.
      env.delete("CI")
      env.delete("SEED")
      # The daemon's own rule, so the two cannot drift: a version bin first on
      # PATH would select the tool's Ruby despite RBENV_VERSION.
      Mutineer::DaemonClient.allocate.send(:scrub_managed_ruby_bins!, env)
      env
    end

    # Fail unless the app-side Ruby matches .ruby-version.
    #
    # @param want [String]
    # @param got [String]
    # @return [void]
    # @raise [Error]
    def verify_ruby!(want, got)
      raise Error, "Fizzy needs Ruby #{want} (.ruby-version), but its bundle ran Ruby #{got}." unless want == got
    end

    # The check runs only committed code, so its result names a real commit.
    #
    # @param head [String] {git_head} output.
    # @return [String] the same SHA.
    # @raise [Error] when the checkout has uncommitted changes.
    def clean_head!(head)
      raise Error, "This checkout has uncommitted changes (#{head}). Commit or stash them, then run fizzy:sample again." if head.end_with?("-dirty")

      head
    end

    # True when the clone already has the commit object, so the fetch can be skipped.
    #
    # @param clone [String]
    # @param sha [String] a full commit SHA.
    # @return [Boolean]
    def commit?(clone, sha)
      _, status = Open3.capture2e("git", "cat-file", "-e", "#{sha}^{commit}", chdir: clone)
      status.success?
    end

    # Hold an exclusive lock on the cache for the block. A second task fails at once.
    #
    # @param cache [String]
    # @yield while holding the lock.
    # @return [Object] the block's value.
    # @raise [Error] when another task holds the lock.
    def with_lock(cache)
      FileUtils.mkdir_p(cache)
      File.open(File.join(cache, "fizzy-sample.lock"), File::RDWR | File::CREAT) do |f|
        raise Error, "another fizzy:sample run is using #{cache}" unless f.flock(File::LOCK_EX | File::LOCK_NB)

        yield
      end
    end

    private

    # report.json, report-meta.json and run.log in the cache.
    #
    # @param cache [String]
    # @return [Array<String>]
    def paths(cache)
      %w[report.json report-meta.json run.log].map { |name| File.join(cache, name) }
    end

    # Fetch the pinned commit into a clean clone, write the config, install gems.
    #
    # @param data [Hash] parsed {DATA}.
    # @param cache [String]
    # @param stale [Array<String>] report files to delete before the run.
    # @return [String] the clone path.
    def prepare!(data, cache, stale)
      clone = File.join(cache, "fizzy")
      step("fetch #{data["repo"]} #{data["commit"]}")
      FileUtils.mkdir_p(clone)
      sh!(clone, "git", "init", "-q") unless File.directory?(File.join(clone, ".git"))
      # A warm cache already has the pinned commit, so later runs need no network.
      sh!(clone, "git", "fetch", "-q", "--depth", "1", data["repo"], data["commit"]) unless commit?(clone, data["commit"])
      sh!(clone, "git", "checkout", "-q", "--force", data["commit"])
      # Removes old logs, worker databases and the coverage cache, which could hide a regression.
      sh!(clone, "git", "clean", "-q", "-fdx")
      FileUtils.rm_f(stale)
      File.write(File.join(clone, ".mutineer.yml"), YAML.dump(CONFIG))
      step("install")
      # .bundle/config, not BUNDLE_PATH: the daemon drops a BUNDLE_PATH it did not inherit.
      sh!(clone, "bundle", "config", "set", "--local", "path", File.join(cache, "gems"))
      sh!(clone, "bundle", "config", "set", "--local", "frozen", "true")
      sh!(clone, "bundle", "install", "--quiet")
      clone
    end

    # Check the app-side Ruby against .ruby-version.
    #
    # @param clone [String]
    # @return [String] the app-side Ruby version.
    def check_ruby!(clone)
      step("ruby check")
      got = sh!(clone, "bundle", "exec", "ruby", "-e", "print RUBY_VERSION")
      verify_ruby!(ruby_version(clone), got)
      got
    end

    # Fizzy's pinned Ruby.
    #
    # @param clone [String]
    # @return [String]
    def ruby_version(clone)
      File.read(File.join(clone, ".ruby-version")).strip
    end

    # Run Mutineer in the clone, stdout and stderr to the log.
    #
    # @param clone [String]
    # @param files [Array<String>]
    # @param report_path [String]
    # @param log [String]
    # @return [Integer, nil] the exit status.
    def run!(clone, files, report_path, log)
      pid = Process.spawn(child_env(ruby_version(clone)), *run_command(files, report_path),
                          chdir: clone, unsetenv_others: true, %i[out err] => [log, "w"])
      Process.wait2(pid).last.exitstatus
    end

    # Run a setup command in the clone's environment and return its output.
    #
    # @param dir [String]
    # @param cmd [Array<String>]
    # @return [String]
    # @raise [Error] naming the command and its output when it fails.
    def sh!(dir, *cmd)
      ruby = File.file?(File.join(dir, ".ruby-version")) ? ruby_version(dir) : RUBY_VERSION
      out, status = Open3.capture2e(child_env(ruby), *cmd, chdir: dir, unsetenv_others: true)
      raise Error, "`#{cmd.join(" ")}` failed in #{dir}:\n#{out}" unless status.success?

      out
    end

    # This checkout's commit, with a `-dirty` suffix when tracked files have
    # uncommitted changes, so {recorded} never stores a SHA that did not produce the counts.
    #
    # @return [String]
    def git_head
      out, status = Open3.capture2e("git", "rev-parse", "HEAD", chdir: ROOT)
      raise Error, "git rev-parse HEAD failed: #{out}" unless status.success?

      changes, status = Open3.capture2e("git", "status", "--porcelain", "--untracked-files=no", chdir: ROOT)
      raise Error, "git status failed: #{changes}" unless status.success?

      changes.strip.empty? ? out.strip : "#{out.strip}-dirty"
    end

    # The environment without this tool's bundle.
    #
    # @return [Hash{String => String}]
    def unbundled_env
      defined?(Bundler) ? Bundler.unbundled_env : ENV.to_h
    end

    # The last {LOG_TAIL} lines of the run log.
    #
    # @param log [String]
    # @return [String]
    def log_tail(log)
      return "(no run log)" unless File.file?(log)

      File.readlines(log).last(LOG_TAIL).join
    end

    # Print one start line per step.
    #
    # @param name [String]
    # @return [void]
    def step(name)
      puts "[fizzy:sample] #{name}"
      $stdout.flush # keep step lines before an abort message on stderr
    end
  end
end
