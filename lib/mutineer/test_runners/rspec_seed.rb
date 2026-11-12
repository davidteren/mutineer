# frozen_string_literal: true

require_relative "../run_seed"

module Mutineer
  module TestRunners
    # Gives a random RSpec order the same seed on the clean check and the
    # mutant runs (#282). A defined order is left as it is: assigning
    # `config.seed` would switch the suite to random. A seed the suite sets
    # (`--seed`, `--order rand:N`, `SPEC_OPTS`, `.rspec`, or `config.seed=`)
    # wins. The hooks install before boot, `--require` files, and spec files
    # load, so a `config.seed=` in any of those is visible. The seed is
    # written after spec files load and before RSpec orders examples.
    #
    # A spec helper that only reads `config.seed` (the generated
    # `Kernel.srand config.seed`) does not count as setting it. The read
    # still sees RSpec's temporary seed; the examples then run under the
    # pinned seed.
    module RSpecSeed
      # Installs the hooks. Idempotent. Requires `rspec/core`, which the
      # caller has already loaded.
      #
      # @api private
      # @return [void]
      def self.install!
        return if ::RSpec::Core::Configuration.ancestors.include?(Watch)

        ::RSpec::Core::Configuration.prepend(Watch)
        ::RSpec::Core::World.prepend(PinBeforeOrder)
      end

      # True while {pin!} is assigning the shared seed, so that assignment
      # is not recorded as the suite's own seed.
      #
      # @api private
      # @return [Boolean]
      def self.pinning?
        @pinning == true
      end

      # True when `value` is an order string that carries a seed, such as
      # `"rand:12"` or `"random:12"`. RSpec stores `--seed N` as
      # `"rand:N"`.
      #
      # @api private
      # @param value [Object]
      # @return [Boolean]
      def self.embedded_seed?(value)
        _order, seed = value.to_s.split(":", 2)
        !seed.nil? && !seed.empty? && seed.match?(/\A\d+\z/)
      end

      # The seed named in the not-green message. `SPEC_OPTS` is what the
      # parent can see. A `.rspec` file or `config.seed` is applied in the
      # child and is not part of this string.
      #
      # @api private
      # @return [String]
      def self.advertised_seed
        opts = ENV.fetch("SPEC_OPTS", "")
        found = opts.scan(/--seed(?:=|\s+)(\d+)/).flatten
        found.concat(opts.scan(/--order(?:=|\s+)rand(?:om)?:(\d+)/).flatten)
        found.last || RunSeed::PINNED_SEED.to_s
      end

      # Sets the shared seed when the loaded suite's order is random and the
      # suite did not set a seed. Re-seeds Ruby's global generator so
      # `rand` in examples matches, after a spec helper's `Kernel.srand`.
      #
      # @api private
      # @param config [RSpec::Core::Configuration]
      # @return [void]
      def self.pin!(config)
        return if config.instance_variable_get(:@mutineer_seed_explicit)
        return unless random_order?(config)

        @pinning = true
        begin
          config.seed = RunSeed::PINNED_SEED
          Kernel.srand(config.seed)
        ensure
          @pinning = false
        end
      end

      # True when the global ordering strategy is RSpec's random one.
      #
      # @api private
      # @param config [RSpec::Core::Configuration]
      # @return [Boolean]
      def self.random_order?(config)
        registry = config.ordering_registry
        registry.fetch(:global).equal?(registry.fetch(:random))
      end

      # Prepended on `RSpec::Core::Configuration`. Records a seed the suite
      # sets, from the command, `SPEC_OPTS`, `.rspec`, or the spec helper.
      module Watch
        # CLI, `SPEC_OPTS` and `.rspec` arrive here. `--seed` is passed as
        # an order of `rand:N`.
        #
        # @param hash [Hash]
        # @return [void]
        def force(hash)
          mark_seed_explicit if hash.key?(:seed) || RSpecSeed.embedded_seed?(hash[:order])
          super
        end

        # A spec helper's `config.seed =`.
        #
        # @param value [Object]
        # @return [void]
        def seed=(value)
          mark_seed_explicit unless RSpecSeed.pinning?
          super
        end

        # A spec helper's `config.order = "rand:N"`.
        #
        # @param value [Object]
        # @return [void]
        def order=(value)
          mark_seed_explicit if RSpecSeed.embedded_seed?(value)
          super
        end

        # Records that this configuration object set its own seed.
        #
        # @api private
        # @return [void]
        def mark_seed_explicit
          @mutineer_seed_explicit = true
        end
      end

      # Prepended on `RSpec::Core::World`. Pins the seed after spec files
      # load and before examples are ordered.
      module PinBeforeOrder
        # The groups RSpec is about to run.
        #
        # @return [Array<RSpec::Core::ExampleGroup>]
        def ordered_example_groups
          RSpecSeed.pin!(::RSpec.configuration)
          super
        end
      end
    end
  end
end
