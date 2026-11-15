# frozen_string_literal: true

require "set" # loads on its own only from Ruby 3.2; the daemon runs on the app's Ruby

module Mutineer
  # Lets the reload strategy run a Rails class body a second time.
  #
  # Reload `load`s the mutant file over a class that is already defined, so the
  # class body runs again. Two Rails macros refuse that:
  #
  # - `enum` raises because the enum's methods already exist (#378).
  # - `skip_callback` (and `skip_before_action`, which calls it) raises because
  #   the first run already removed the callback (#384).
  #
  # While {.during_load} runs, an `enum` the class had before the load skips
  # its conflict check, and `skip_callback` does not raise for a callback the
  # first run already removed (see {CallbackReskipping}).
  # The original file ran the same macros once with the full checks, so the
  # second run repeats work Rails already accepted. Outside the load, for
  # example while the tests run, both macros check as usual.
  #
  # {.during_load} also loads the original file first when the app autoloads it
  # and nothing has loaded it yet (#383). Ruby would do that anyway when the
  # mutant reopens the constant, but inside the load, after
  # {ConcernBlocks.forget}, so the concern's original `included` block would
  # come back and the mutant's block would raise `MultipleIncludedBlocks`.
  #
  # A second run of the class body also adds each block callback, lambda
  # callback and validator again. Rails replaces a repeated callback only when
  # it names a method. So {.during_load} removes the original's copy of each
  # one the load added again (see {RepeatedCallbacks}, #390). Otherwise a
  # `validates` or a `before_save do ... end` would run twice in every mutant
  # of the file, and a test that counts errors or side effects would give a
  # false kill.
  #
  # Call it only in a forked child that loads the mutant: it prepends onto
  # Rails modules in that process. Without Rails it only runs the block.
  #
  # Stdlib-only, so the app-side daemon can load it.
  module ReloadGuards
    # Skips the conflict check for an enum the class defined before the mutant
    # load began, during that load only.
    module EnumRedeclaration
      private

      # @param enum_name [Symbol, String] the enum being declared.
      # @return [void]
      def detect_enum_conflict!(enum_name, *)
        return if ReloadGuards.loading? && ReloadGuards.enum_existed?(self, enum_name)

        super
      end
    end

    # Makes a repeated skip a no-op, during a mutant load only. The class body
    # outside methods is the original's, and the original's first run already
    # removed the callback from this class, so a skip there is a repeat. It
    # counts as one when each filter is a method the class has (a callback the
    # parent or an included concern installed) or a callback the parent still
    # has. A skip that names neither keeps Rails' check and still raises
    # (scored `error`), so a typo is not hidden.
    module CallbackReskipping
      # @param name [Symbol] the callback chain, such as `:save`.
      # @param filter_list [Array] the kind, the filters, and options.
      # @return [void]
      def skip_callback(name, *filter_list, &block)
        return super unless ReloadGuards.loading?

        options = filter_list.last.is_a?(Hash) ? filter_list.pop : {}
        options = { raise: false }.merge(options) if ReloadGuards.repeated_skip?(self, name, *filter_list)
        super(name, *filter_list, options, &block)
      end
    end

    # True while a mutant file loads.
    #
    # @return [Boolean]
    def self.loading?
      @loading == true
    end

    # Loads the original file if the app autoloads it, then runs the block that
    # loads the mutant with the guards on. After the block, removes the
    # original's copy of each callback and validator the load added again.
    #
    # @param source_file [String] the file the mutant replaces.
    # @param mutant_path [String, nil] the file the block loads.
    # @yield the mutant's load.
    # @return [Object] what the block returns.
    def self.during_load(source_file, mutant_path = nil)
      load_original(source_file)
      install!
      before = RepeatedCallbacks.snapshot
      @enums_before_load = {}
      @loading = true
      result = yield
      RepeatedCallbacks.remove(before, [source_file, mutant_path].compact)
      result
    ensure
      @loading = false
    end

    # Puts back one copy of each callback and validator that a second run of a
    # class body added again (#390).
    #
    # Each class body the load runs again appends its block callbacks, lambda
    # callbacks and validators a second time. Rails drops the old copy only of
    # a callback that names a method, and appends the new one at the end. For
    # each class whose chains the load changed, {.replacements} pairs each
    # entry the load added to the class's own chain with the class's own entry
    # from before the load that it repeats. {.restore} then puts each new entry
    # where its old entry was and drops the old one, in every changed chain and
    # in `_validators`. So each macro runs once, in its original order.
    #
    # An included concern adds its entries to the class, and the reload does
    # not run its block again, so it adds no new copy of them. Its entries can
    # look like the class body's own, so entries pair first with old entries
    # that are the same ({.same?}): a validator with equivalent options, a
    # lambda that captured equivalent values, a block from the same place in
    # the code. They pair only when there are as many old ones as new ones
    # ({.exact_pairs}). An entry left over pairs by {.key}. The key is the
    # callback kind, the filter, and its `if:` / `unless:` conditions. A
    # `&:name` proc's filter is that symbol. A block's filter is its place
    # and its code, not a value it captured. A validator's filter is its
    # class, its attributes and its option names, not values a method the
    # mutant changed can return. A concern entry that differs on any of
    # those is not a candidate, so the class body's repeat can pair. One
    # that is the same on all of them still shares the key, and the pair is
    # kept only when the counts match, so a guess cannot drop the concern's
    # entry. Otherwise both copies stay (#413). Full reload (#389) builds
    # the class once, which is what can separate those identical entries.
    # Redefine does not run the class body again, so it never adds the copy.
    #
    # ActiveSupport gives a class a new chain object each time a callback is
    # added or skipped, so a class whose chain objects all stay the same was
    # not changed by the load and is skipped.
    module RepeatedCallbacks
      # Every loaded class with ActiveSupport callbacks, with its chain objects.
      #
      # @return [Hash{Class => Hash{Symbol => Object}}] empty without ActiveSupport.
      def self.snapshot
        return {} unless ReloadGuards.callbacks_loaded?

        # Asks the module: a class can define its own `<` (`extend Comparable`).
        classes = ObjectSpace.each_object(Class).select { |klass| ::ActiveSupport::Callbacks > klass }
        classes.to_h { |klass| [klass, klass.__callbacks.dup] }
      end

      # Keeps one copy of each entry the load added again.
      #
      # @param before [Hash] the {.snapshot} from before the load.
      # @param files [Array<String>] the source file and the mutant file. A
      #   block from either one counts as a block from the same file.
      # @return [void]
      def self.remove(before, files)
        changed = before.keys.reject { |klass| same_chains?(klass.__callbacks, before[klass]) }
        return if changed.empty?

        reloaded = files.map { |file| real_path(file) }
        # Each class's entries before the load, copied only for the classes asked.
        old = Hash.new { |copies, klass| copies[klass] = before.fetch(klass, {}).transform_values(&:to_a) }
        by_chain = {}
        changed.each do |klass|
          replacements(klass, old, reloaded).each do |name, pairs|
            by_chain[[klass, name]] = pairs
          end
        end
        restore(changed, old, by_chain) unless by_chain.empty?
      end

      # @param now [Hash{Symbol => Object}] a class's chains after the load.
      # @param before [Hash{Symbol => Object}] its chains before the load.
      # @return [Boolean] true when every chain is the same object as before.
      def self.same_chains?(now, before)
        now.size == before.size && now.all? { |name, chain| before[name].equal?(chain) }
      end

      # Pairs each entry the load added to `klass`'s own chains with the old
      # entry it repeats: first with old entries that are the same
      # ({.exact_pairs}), then by key. A mutant can change a block's body, so
      # the code no longer matches. Leftovers that share a place and have
      # equal counts pair without the code ({.by_key} with `code: false`).
      # A concern that shares only that place still makes the counts differ.
      #
      # @param klass [Class] a class whose chains the load changed.
      # @param old [Hash{Class => Hash{Symbol => Array}}] each class's entries before the load.
      # @param reloaded [Array<String>] real paths of the source and mutant files.
      # @return [Hash{Symbol => Array<Array(Object, Object)>}] for each chain
      #   name, each old entry and the new entry that replaces it.
      def self.replacements(klass, old, reloaded)
        parent = klass.superclass
        parent_now = parent.respond_to?(:__callbacks) ? parent.__callbacks : {}
        parent_old = old[parent]
        pairs = {}
        klass.__callbacks.each do |name, chain|
          before = old[klass].fetch(name, [])
          added = without(without(chain.to_a, before), parent_now[name].to_a)
          next if added.empty?

          pool = without(before, parent_old.fetch(name, []))
          exact = exact_pairs(added, pool, reloaded)
          rest = without(added, exact.map(&:last))
          keyed = by_key(rest, pool, reloaded)
          loose = by_key(without(rest, keyed.map(&:last)), without(pool, keyed.map(&:first)), reloaded, code: false)
          matched = exact + keyed + loose
          pairs[name] = matched unless matched.empty?
        end
        pairs
      end

      # Pairs new entries with the old entries that are the same ({.same?}),
      # in order, but only when there are as many old ones as new ones. The
      # class body can add a callback once only (`@done ||= ...`), or a
      # concern can hold a look-alike, so a different count keeps both
      # copies, as before #390. Removes the paired old entries from `pool`.
      #
      # @param added [Array] the entries the load added.
      # @param pool [Array] the old entries that could be repeated.
      # @param reloaded [Array<String>] real paths of the source and mutant files.
      # @return [Array<Array(Object, Object)>] each old entry and the new entry that replaces it.
      def self.exact_pairs(added, pool, reloaded)
        seen = {}
        rest = added
        pairs = []
        until rest.empty?
          first = rest.first
          group, rest = rest.partition { |entry| same?(entry, first, reloaded, seen) }
          olds = pool.select { |entry| same?(entry, first, reloaded, seen) }
          next unless olds.size == group.size

          pool.replace(without(pool, olds))
          pairs.concat(olds.zip(group))
        end
        pairs
      end

      # Pairs the entries no exact match took, by {.key}, but only for a key
      # with as many old entries left as new ones. More old entries means an
      # included concern added some of them, and a guess could drop the
      # concern's entry. Those keep both copies, as before #390.
      #
      # @param added [Array] new entries with no exact match.
      # @param pool [Array] old entries no exact match took.
      # @param reloaded [Array<String>] real paths of the source and mutant files.
      # @param code [Boolean] when false, a block's compiled body is left out
      #   of the key, so a mutant of that body still pairs.
      # @return [Array<Array(Object, Object)>] each old entry and the new entry that replaces it.
      def self.by_key(added, pool, reloaded, code: true)
        old_by_key = pool.group_by { |entry| key(entry, reloaded, code: code) }
        added.group_by { |entry| key(entry, reloaded, code: code) }.flat_map do |k, new_entries|
          old_entries = old_by_key.fetch(k, [])
          old_entries.size == new_entries.size ? old_entries.zip(new_entries) : []
        end
      end

      # Rebuilds each changed chain in its order from before the load, with
      # each old entry swapped for its new entry, and entries the load added
      # unpaired at the end. Swaps each validator in `_validators` the same way.
      #
      # @param changed [Array<Class>] the classes whose chains the load changed.
      # @param old [Hash{Class => Hash{Symbol => Array}}] each class's entries before the load.
      # @param by_chain [Hash{Array(Class, Symbol) => Array<Array(Object, Object)>}]
      #   each class and chain name, with the old and new entries paired there.
      # @return [void]
      def self.restore(changed, old, by_chain)
        seen = {}.compare_by_identity
        changed.each do |klass|
          klass.__callbacks.each do |name, chain|
            next if seen[chain]

            seen[chain] = true
            now = chain.to_a
            order = reorder(old[klass].fetch(name, []), now, swap_for(klass, name, by_chain))
            next if order.size == now.size && order.zip(now).all? { |a, b| a.equal?(b) }

            chain.clear
            chain.append(*order)
          end
        end
        # A validator is the filter of its `validate` callback. The same
        # validator object can sit on a subclass, so every pair counts here.
        validators = {}.compare_by_identity
        by_chain.each_value do |pairs|
          pairs.each { |old_entry, new_entry| validators[old_entry.filter] = new_entry.filter }
        end
        lists = changed.select { |klass| klass.respond_to?(:_validators) }.flat_map { |klass| klass._validators.values }
        lists.uniq(&:object_id).each do |list|
          list.map! { |validator| validators.fetch(validator, validator) }
          list.uniq!(&:object_id)
        end
      end

      # A paired new entry whose old entry this chain did not have came from an
      # ancestor's class body, for this same chain name. Rails appends a
      # parent's callback to every loaded subclass, so it also reached a
      # subclass that skipped it (#414). Such an entry is dropped. A
      # replacement on another chain name, or on a class that is not an
      # ancestor, is not such an entry: that chain keeps it. When Rails
      # dropped the subclass's own copy as a duplicate, such as the
      # conditional copy that a `skip_callback ... if:` leaves, that copy
      # comes back.
      #
      # @param old [Array] the chain's entries before the load.
      # @param now [Array] its entries after the load.
      # @param swap [Hash{Object => Object}] each old entry to its new entry.
      # @return [Array] `old` with each new entry swapped in, then the other new entries.
      def self.reorder(old, now, swap)
        present = identity_set(now)
        paired = identity_set(swap.values)
        kept = identity_set(old.filter_map { |entry| swap[entry] })
        stray = now.select { |entry| paired.include?(entry) && !kept.include?(entry) }
        order = old.filter_map do |entry|
          new_entry = swap[entry]
          next new_entry if new_entry && present.include?(new_entry)

          entry if present.include?(entry) || stray.any? { |other| displaced?(entry, other) }
        end
        order + without(now, order).reject { |entry| swap.key?(entry) || paired.include?(entry) }
      end

      # Pairs for `name` on `klass` and on each of its ancestors. Rails appends
      # one reloaded callback onto descendants of that class, and only onto
      # this chain name. A pair from any other chain must not drop an entry
      # here.
      #
      # @param klass [Class] the class whose chain is being rebuilt.
      # @param name [Symbol] the chain name, such as `:save`.
      # @param by_chain [Hash{Array(Class, Symbol) => Array<Array(Object, Object)>}]
      #   see {restore}.
      # @return [Hash{Object => Object}] each old entry to its new entry.
      def self.swap_for(klass, name, by_chain)
        swap = {}.compare_by_identity
        owners(klass).each do |owner|
          by_chain[[owner, name]]&.each { |old_entry, new_entry| swap[old_entry] = new_entry }
        end
        swap
      end

      # @param klass [Class]
      # @return [Array<Class>] `klass` and its ancestors, furthest first.
      def self.owners(klass)
        owners = []
        current = klass
        while current.is_a?(Class)
          owners << current
          current = current.superclass
        end
        owners.reverse
      end

      # @param entry [Object] an old ActiveSupport callback.
      # @param other [Object] a new one.
      # @return [Boolean] true when Rails drops `entry` on appending `other`:
      #   both name the same method, with the same kind.
      def self.displaced?(entry, other)
        entry.filter.is_a?(Symbol) && entry.kind == other.kind && entry.filter == other.filter
      end

      # True when two entries come from the same macro call with the same
      # arguments: the same kind, and filters and `if:`/`unless:` conditions
      # that are {.equivalent?}. A concern and the class body can add one
      # callback class under different conditions; those are different entries.
      #
      # @param old_entry [Object] an ActiveSupport callback from before the load.
      # @param new_entry [Object] one the load added.
      # @param reloaded [Array<String>] real paths of the source and mutant files.
      # @param seen [Hash] answers already found ({.equivalent?}).
      # @return [Boolean]
      def self.same?(old_entry, new_entry, reloaded, seen = {})
        old_entry.kind == new_entry.kind && equivalent?(old_entry.filter, new_entry.filter, reloaded, 0, seen) &&
          equivalent?(conditions(old_entry), conditions(new_entry), reloaded, 0, seen)
      end

      # @param callback [Object] an ActiveSupport callback.
      # @return [Array] its `if:` and `unless:` conditions, as ActiveSupport
      #   keeps them (empty lists when it keeps none).
      def self.conditions(callback)
        %i[@if @unless].map { |name| callback.instance_variable_get(name) || [] }
      end

      # How deep {.equivalent?} looks into objects before it gives up.
      EQUIVALENT_DEPTH = 6

      # True when two values would make the same callback or validator. Each
      # run of a class body builds new blocks, so a block matches another
      # from the same place in the code ({.block_key}) that captured
      # equivalent values. Hashes and arrays match element by element. A class
      # or module matches only itself. Other objects, such as a validator or a
      # callback object, match when they are equal, or of one class with
      # equivalent instance variables. Past {EQUIVALENT_DEPTH} levels nothing
      # matches, so a deep object pairs only by key ({.by_key}).
      #
      # A pair already being compared, such as a lambda that captures itself
      # (Rails's `belongs_to touch:` lambda does), counts as a match: nothing
      # else in it differs. Each answer is kept in `seen`, so a value many
      # blocks capture is compared once. A value that cannot be compared, such
      # as the proxy `with_options` yields, matches nothing, so both copies stay.
      #
      # @param left [Object]
      # @param right [Object]
      # @param reloaded [Array<String>] real paths of the source and mutant files.
      # @param depth [Integer] levels already compared.
      # @param seen [Hash{Array => Boolean, Symbol}] each pair's answer, or
      #   `:open` while it is being compared, by object id.
      # @return [Boolean]
      def self.equivalent?(left, right, reloaded, depth = 0, seen = {})
        return true if SAME_OBJECT.bind_call(left, right)

        pair = [left.__id__, right.__id__]
        return seen[pair] != false if seen.key?(pair)
        return false if depth > EQUIVALENT_DEPTH || !INSTANCE_OF.bind_call(left, KERNEL_CLASS.bind_call(right))

        seen[pair] = :open
        same = ->(a, b) { equivalent?(a, b, reloaded, depth + 1, seen) }
        seen[pair] = case left
                     when Module then false
                     when Proc then same_block?(left, right, reloaded, same)
                     when Hash then left.keys == right.keys && left.all? { |k, v| same.(v, right[k]) }
                     when Array then left.size == right.size && left.zip(right).all? { |a, b| same.(a, b) }
                     else left == right || same_state?(left, right, same)
                     end
      rescue StandardError
        seen[pair] = false if pair
        false
      end

      # `BasicObject#equal?`, unbound, so a proxy cannot answer for its target.
      SAME_OBJECT = ::BasicObject.instance_method(:equal?)

      # `Kernel#instance_of?`, unbound, for the same reason.
      INSTANCE_OF = ::Kernel.instance_method(:instance_of?)

      # `Kernel#class`, unbound, for the same reason.
      KERNEL_CLASS = ::Kernel.instance_method(:class)

      # @param left [Object]
      # @param right [Object] an object of the same class.
      # @param same [Proc] compares two values one level deeper.
      # @return [Boolean] true when the instance variables both have are
      #   equivalent. One of them can hold a value the other has not cached
      #   yet, such as a Rails reflection's memoized lookups, so the others are
      #   skipped. No shared variables is not a match: a symbol or a number
      #   has none, and those compare by value.
      def self.same_state?(left, right, same)
        names = left.instance_variables & right.instance_variables
        return false if names.empty?

        names.all? { |name| same.(left.instance_variable_get(name), right.instance_variable_get(name)) }
      end

      # @param left [Proc]
      # @param right [Proc]
      # @param reloaded [Array<String>] real paths of the source and mutant files.
      # @param same [Proc] compares two values one level deeper.
      # @return [Boolean] true for blocks from the same place in the code that
      #   captured equivalent values. A `&:name` proc has no source and
      #   captures nothing; it matches another for the same symbol (#413).
      #   `method(:x).to_proc` still matches only through its source and the
      #   receiver it captured.
      def self.same_block?(left, right, reloaded, same)
        left_symbol = symbol_proc_text(left)
        right_symbol = symbol_proc_text(right)
        return left_symbol == right_symbol if left_symbol || right_symbol
        return false unless left.source_location && right.source_location

        block_key(left, reloaded) == block_key(right, reloaded) && same_captures?(left, right, same)
      end

      # @param left [Proc]
      # @param right [Proc] a block from the same place in the code.
      # @param same [Proc] compares two values one level deeper.
      # @return [Boolean] true when both captured equivalent values. The list
      #   itself is not a level, so blocks that capture each other in a loop
      #   reach the pair already being compared before the depth limit.
      def self.same_captures?(left, right, same)
        mine = captured(left)
        theirs = captured(right)
        return false unless mine && theirs && mine.size == theirs.size

        mine.zip(theirs).all? { |a, b| same.(a, b) }
      end

      # The block's receiver and the values it captured, or nil when Ruby
      # cannot show them. The receiver tells apart `method(:x).to_proc` of
      # two objects; a class body's blocks share the class as receiver.
      #
      # @param block [Proc]
      # @return [Array, nil]
      def self.captured(block)
        scope = block.binding
        [scope.receiver] + scope.local_variables.map { |name| scope.local_variable_get(name) }
      rescue ArgumentError
        nil
      end

      # Where a block sits in the code: the file and Ruby's label for it, such
      # as "block in <class:Parcel>", plus the line for a file the load did
      # not run, plus the block's code ({.block_code}). The source file and
      # the mutant file count as one file, and their lines are left out,
      # because a mutant can move lines. Two blocks that share a label and
      # differ in code are different callbacks (#413). A `&:name` proc is
      # the symbol Ruby prints for it, so `:normalize` does not share a key
      # with `:touch`.
      #
      # @param block [Proc]
      # @param reloaded [Array<String>] real paths of the source and mutant files.
      # @param code [Boolean] when false, the compiled body is left out. A
      #   mutant of that body then shares the key of the block it replaced.
      # @return [Array]
      def self.block_key(block, reloaded, code: true)
        symbol = symbol_proc_text(block)
        return [:symbol, symbol] if symbol

        file, line = block.source_location
        # CRuby only; elsewhere blocks match by file and line alone.
        label = RubyVM::InstructionSequence.of(block)&.label if defined?(::RubyVM::InstructionSequence)
        compiled = block_code(block, reloaded) if code
        reloaded.include?(file && real_path(file)) ? [:reloaded, label, compiled] : [file, line, label, compiled]
      end

      # CRuby prints `Symbol#to_proc` as `#<Proc:0xaddr(&:name) (lambda)>`.
      # The text after `&` is the symbol's own inspect. The cache holds 67
      # of these procs, so a later `&:other` can make the next `&:name` a
      # new object; the text still matches (#413).
      SYMBOL_PROC = /\A#<Proc:0x[0-9a-fA-F]+\(&(.+)\) \(lambda\)>\z/

      # @param block [Proc]
      # @return [String, nil] the symbol text, such as `":normalize"`, or nil
      #   when `block` is not a `Symbol#to_proc`.
      def self.symbol_proc_text(block)
        SYMBOL_PROC.match(block.to_s)&.[](1) if block.is_a?(::Proc)
      end

      # Magic `InstructionSequence#to_a` starts with. A different format has
      # no code identity, so the block matches by file and label only.
      ISEQ_FORMAT = "YARVInstructionSequence/SimpleDataFormat"

      # Fields of an instruction sequence that stay the same when the same
      # block is compiled again. Node ids and code locations change on every
      # load, so they are left out.
      ISEQ_MISC_KEYS = %i[arg_size local_size stack_max parser].freeze

      # The block's code, with locations removed, or nil when Ruby cannot
      # show it. A value the block captured is not part of the code, so a
      # new object, a time or a random value still pairs (#413). `__FILE__`
      # is the source path in one load and the mutant path in the other;
      # both become the same placeholder. A `rescue` or `ensure` keeps a
      # nested sequence in the catch table; that sequence is normalized
      # too, or the two copies would not pair.
      #
      # @param block [Proc]
      # @param reloaded [Array<String>] real paths of the source and mutant files.
      # @return [Array, nil]
      def self.block_code(block, reloaded)
        return unless defined?(::RubyVM::InstructionSequence)

        iseq = ::RubyVM::InstructionSequence.of(block)
        return unless iseq

        data = iseq.to_a
        return unless data.is_a?(Array) && data[0] == ISEQ_FORMAT && data[4].is_a?(Hash)

        file, = block.source_location
        paths = [file, *reloaded].compact.flat_map { |path| [path, real_path(path)] }.uniq
        code_identity(data, paths)
      rescue StandardError
        nil
      end

      # @param data [Array] one `InstructionSequence#to_a` array.
      # @param paths [Array<String>] paths to treat as the reloaded file.
      # @return [Array]
      def self.code_identity(data, paths)
        misc = ISEQ_MISC_KEYS.to_h { |key| [key, data[4][key]] }
        [data[5], misc, data[9], data[10], data[11], strip_code(data[12], paths), strip_code(data[13], paths)]
      end

      # @param node [Object] one node of an instruction sequence.
      # @param paths [Array<String>] paths to treat as the reloaded file.
      # @return [Object] `node` with line numbers and those paths removed.
      #   A bare integer in an instruction list is a line number, including
      #   one in the middle of a `rescue` or `ensure` body. An integer that
      #   is an operand, such as `[:getlocal_WC_0, 3]`, stays.
      def self.strip_code(node, paths)
        case node
        when Array
          if iseq_node?(node)
            code_identity(node, paths)
          elsif instruction_body?(node)
            node.filter_map { |child| strip_code(child, paths) unless child.is_a?(Integer) }
          else
            node.map { |child| strip_code(child, paths) }
          end
        when String
          paths.include?(node) ? :reloaded_path : node
        when Hash
          node.to_h { |key, value| [strip_code(key, paths), strip_code(value, paths)] }
        else
          node
        end
      end

      # A real instruction sequence, not an array a callback happened to
      # build. The magic string alone is not enough: the node also has the
      # misc hash, a label, and a bytecode array. Anything else stays an
      # array, so it cannot blank the block's code identity.
      #
      # @param node [Array]
      # @return [Boolean]
      def self.iseq_node?(node)
        node[0] == ISEQ_FORMAT && node[4].is_a?(Hash) && node[5].is_a?(String) && node[13].is_a?(Array)
      end

      # @param node [Array] one array from an instruction sequence.
      # @return [Boolean] true when `node` is a list of instructions rather
      #   than one instruction's operands.
      def self.instruction_body?(node)
        node.any? { |child| child.is_a?(Symbol) && child.to_s.start_with?("RUBY_EVENT_") }
      end

      # What two entries share when they are copies of one macro call, apart
      # from values a mutant can change. A callback that names a method
      # matches the same name. A block or lambda matches by {.block_key}.
      # A validator matches by class, attributes and option names, not option
      # values. `if:` and `unless:` are part of the key, so the same filter
      # under a different condition is a different callback (#413).
      #
      # @param callback [Object] an ActiveSupport callback.
      # @param reloaded [Array<String>] real paths of the source and mutant files.
      # @param code [Boolean] see {block_key}.
      # @return [Array]
      def self.key(callback, reloaded, code: true)
        filter = callback.filter
        filter_key = case filter
                     when Symbol, Module then filter
                     when Proc then block_key(filter, reloaded, code: code)
                     else object_key(filter)
                     end
        [callback.kind, filter_key, condition_key(callback, reloaded, code: code)]
      end

      # @param filter [Object] a callback filter that is not a symbol, module or proc.
      # @return [Array] its class, attributes and option names.
      def self.object_key(filter)
        attributes = filter.attributes if filter.respond_to?(:attributes)
        shape = option_shape(filter.options) if filter.respond_to?(:options)
        [filter.class, attributes, shape]
      end

      # Option names, nested, without the values. A method the mutant changed
      # can return a different value; the names in the class body stay.
      #
      # @param value [Object] a validator's options, or a nested value.
      # @return [Array, nil] nil when `value` is not a Hash.
      def self.option_shape(value)
        return unless value.is_a?(Hash)

        value.keys.sort_by(&:to_s).map { |key| [key, option_shape(value[key])] }
      end

      # @param callback [Object] an ActiveSupport callback.
      # @param reloaded [Array<String>] real paths of the source and mutant files.
      # @param code [Boolean] see {block_key}.
      # @return [Array] its `if:` and `unless:` conditions, as keys. A proc
      #   condition uses {.block_key}, so a captured value that changes on
      #   each load does not hide the repeat.
      def self.condition_key(callback, reloaded, code: true)
        conditions(callback).map do |list|
          Array(list).map { |item| condition_item_key(item, reloaded, code: code) }
        end
      end

      # @param item [Object] one `if:` or `unless:` condition.
      # @param reloaded [Array<String>] real paths of the source and mutant files.
      # @param code [Boolean] see {block_key}.
      # @return [Object]
      def self.condition_item_key(item, reloaded, code: true)
        case item
        when Proc then block_key(item, reloaded, code: code)
        when Symbol, Module, Numeric, String, TrueClass, FalseClass, NilClass then item
        else item.class
        end
      end

      # @param list [Array]
      # @param others [Array]
      # @return [Array] the entries of `list` that are not in `others`, by identity.
      def self.without(list, others)
        others = identity_set(others)
        list.reject { |entry| others.include?(entry) }
      end

      # A set that compares by identity. Building it first keeps entries that
      # are equal by value but not the same object.
      #
      # @param list [Array]
      # @return [Set]
      def self.identity_set(list)
        Set.new.compare_by_identity.merge(list)
      end

      # @param file [String]
      # @return [String] the real path, so a symlinked path still matches.
      def self.real_path(file)
        (@real_paths ||= {})[file] ||= begin
          File.realpath(file)
        rescue SystemCallError
          File.expand_path(file)
        end
      end
    end

    # Whether `klass` had the enum before this load. Rails records a new enum
    # after its first conflict check, so the answer is read once, at the first
    # check of each enum, and kept for the rest of the load.
    #
    # @param klass [Class] the model declaring the enum.
    # @param enum_name [Symbol, String] the enum being declared.
    # @return [Boolean]
    def self.enum_existed?(klass, enum_name)
      key = [klass, enum_name.to_s]
      @enums_before_load.fetch(key) { @enums_before_load[key] = klass.defined_enums.key?(key.last) }
    end

    # The callback kinds `skip_callback` takes before its filters.
    CALLBACK_KINDS = %i[before after around].freeze

    # True when every filter of this skip is a method `klass` has, or a callback
    # of that kind on chain `name` that the superclass still has. The kind is
    # optional and defaults to `:before`, as in Rails. With no filters there is
    # nothing to compare, so false.
    #
    # @param klass [Class] the class calling `skip_callback`.
    # @param name [Symbol] the callback chain, such as `:save`.
    # @param args [Array] the optional kind, then the filters.
    # @return [Boolean]
    def self.repeated_skip?(klass, name, *args)
      kind = CALLBACK_KINDS.include?(args.first) ? args.shift : :before
      return false if args.empty?

      parent = klass.superclass
      chain = parent.respond_to?(:__callbacks) ? parent.__callbacks[name] : nil
      args.all? do |filter|
        (filter.is_a?(Symbol) && (klass.method_defined?(filter) || klass.private_method_defined?(filter))) ||
          chain&.any? { |callback| callback.kind == kind && callback.filter == filter }
      end
    end

    # Prepends the guards once, onto the Rails modules this process has loaded.
    # A module Rails only set to autoload stays unloaded, so the mutant run
    # sees the same Ruby as the clean run.
    #
    # @return [void]
    def self.install!
      if defined?(::ActiveRecord::Enum) && !::ActiveRecord.autoload?(:Enum)
        prepend_once(::ActiveRecord::Enum, EnumRedeclaration)
      end
      return unless callbacks_loaded?

      prepend_once(::ActiveSupport::Callbacks::ClassMethods, CallbackReskipping)
    end

    # `defined?` does not load an autoloaded constant, but using it does.
    #
    # @return [Boolean] true when `ActiveSupport::Callbacks` is loaded, not
    #   only set to autoload.
    def self.callbacks_loaded?
      !!defined?(::ActiveSupport::Callbacks) && !::ActiveSupport.autoload?(:Callbacks)
    end

    # @param target [Module] the Rails module.
    # @param guard [Module] the guard to put in front of it.
    # @return [void]
    def self.prepend_once(target, guard)
      target.prepend(guard) unless target.ancestors.include?(guard)
    end

    # Asks each Rails autoloader for the constant `source_file` defines. A
    # loader that does not manage the file raises `Zeitwerk::Error`; the next
    # one is asked. A managed file that does not define the constant Zeitwerk
    # expects raises `Zeitwerk::NameError`, a `NameError`; the mutant load goes
    # on as before. A file already loaded only costs a constant lookup.
    # Autoload roots are real paths, so the loaders get the real path.
    #
    # @param source_file [String] the file the mutant replaces.
    # @return [void]
    def self.load_original(source_file)
      return unless defined?(::Rails) && ::Rails.respond_to?(:autoloaders) && defined?(::Zeitwerk::Error)
      # A library can load railties with no Rails app; `Rails.autoloaders` then raises.
      return unless ::Rails.respond_to?(:application) && ::Rails.application

      ::Rails.autoloaders.each do |loader|
        next unless loader.respond_to?(:load_file)

        begin
          loader.load_file(RepeatedCallbacks.real_path(source_file))
          return
        rescue ::Zeitwerk::Error, ::NameError
          next
        end
      end
    end
  end
end
