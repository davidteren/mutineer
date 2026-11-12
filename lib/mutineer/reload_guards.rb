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
    # ({.exact_pairs}). An entry left over, such as a `validates` whose options come
    # from a method the mutant changed, pairs by {.key} only when no concern
    # entry could be the one it repeats ({.by_key}). Otherwise both copies stay,
    # as before this fix.
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
      # ({.exact_pairs}), then by key.
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
          matched = exact + by_key(without(added, exact.map(&:last)), pool, reloaded)
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
      # @return [Array<Array(Object, Object)>] each old entry and the new entry that replaces it.
      def self.by_key(added, pool, reloaded)
        old_by_key = pool.group_by { |entry| key(entry, reloaded) }
        added.group_by { |entry| key(entry, reloaded) }.flat_map do |k, new_entries|
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
      # comes back. A copy that still holds its ancestor's conditions from
      # before this load is rebuilt from the reloaded callback, so a mutant
      # of those conditions reaches the subclass (#440). Reload and the
      # daemon run this path. Redefine does not re-run the class body.
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
          next entry if present.include?(entry)

          other = merge_stray(entry, stray, swap)
          if other
            restored(entry, other, swap)
          elsif stray.any? { |candidate| displaced?(entry, candidate) }
            entry
          end
        end
        order + without(now, order).reject { |entry| swap.key?(entry) || paired.include?(entry) }
      end

      # The callback to put back when Rails dropped `entry` as a duplicate of
      # `stray`. `skip_callback` with `if:` or `unless:` builds `entry` by
      # copying the parent's condition objects and appending the subclass's
      # own. Putting that object back would keep the parent's conditions from
      # before the reload (#440). When those objects are still the parent's
      # previous ones, this rebuilds `entry` from `stray` through
      # `merge_conditional_options`, the same merge `skip_callback` uses: a
      # subclass `if:` is stored on `unless`, and a subclass `unless:` on
      # `if`. A copy that does not hold those objects is the subclass's own
      # callback and stays. A parent that had no conditions has no objects to
      # match, so its copy stays too (#414): a subclass callback of the same
      # name is not rewritten. A list of only symbols, or other interned
      # objects, is not evidence either. An independent callback can name the
      # same symbol. No issue is filed for that remainder yet. A copied Proc
      # is evidence, and that Proc is carried. The old copy also stays when
      # `stray` still has those same condition objects.
      #
      # @param entry [Object] the subclass callback Rails dropped.
      # @param stray [Object] the ancestor callback appended in its place.
      # @param swap [Hash{Object => Object}] each old entry to its new entry.
      # @return [Object] `entry`, or the rebuilt callback.
      def self.restored(entry, stray, swap)
        parent = merge_source(entry, stray, swap)
        return entry unless parent
        return entry if same_conditions?(stray, parent)
        return entry unless stray.respond_to?(:merge_conditional_options)

        extra_if, extra_unless = extra_conditions(entry, parent)
        stray.merge_conditional_options(
          chain_view(stray), if_option: extra_unless, unless_option: extra_if
        )
      end

      # The nearest old callback that `swap` maps to `stray` and that {restored}
      # can show `entry` was merged from. Ancestors are inserted furthest
      # first, so the last match is the nearest class that reloaded `stray`.
      #
      # @param entry [Object] the subclass callback Rails dropped.
      # @param stray [Object] the ancestor callback appended in its place.
      # @param swap [Hash{Object => Object}] each old entry to its new entry.
      # @return [Object, nil] that old callback, or nil when `entry` is not its merge.
      def self.merge_source(entry, stray, swap)
        found = nil
        swap.each do |old_entry, new_entry|
          found = old_entry if new_entry.equal?(stray) && merged_from?(entry, old_entry)
        end
        found
      end

      # The reloaded callback `entry` was merged from, when several ancestors
      # appended a callback of the same name. The first of those is not always
      # the one. {displaced?} only compares the method name and the kind.
      #
      # @param entry [Object] the subclass callback Rails dropped.
      # @param stray [Array] new callbacks this chain did not have.
      # @param swap [Hash{Object => Object}] each old entry to its new entry.
      # @return [Object, nil] the stray to rebuild from, or nil.
      def self.merge_stray(entry, stray, swap)
        stray.find { |candidate| displaced?(entry, candidate) && merge_source(entry, candidate, swap) }
      end

      # @param entry [Object] a callback left by `skip_callback`.
      # @param parent [Object] the ancestor callback it was merged from.
      # @return [Boolean] true when `entry`'s conditions still start with
      #   `parent`'s condition objects, and one of those objects is not
      #   interned. `skip_callback` copies those objects. A parent with no
      #   conditions matches every copy, so that is not evidence. A symbol is
      #   the same object wherever it is written, so it is not evidence
      #   either. No issue is filed for a symbol-only parent condition yet.
      def self.merged_from?(entry, parent)
        entry_if, entry_unless = conditions(entry)
        parent_if, parent_unless = conditions(parent)
        return false if parent_if.empty? && parent_unless.empty?
        return false unless prefix?(entry_if, parent_if) && prefix?(entry_unless, parent_unless)

        (parent_if + parent_unless).any? { |item| !interned_condition?(item) }
      end

      # @param object [Object] one `if:` or `unless:` condition.
      # @return [Boolean] true for nil, true, false, a Symbol, or an Integer.
      #   Those are the same object wherever they are written. A Proc is not.
      def self.interned_condition?(object)
        object.nil? || same_object?(object, true) || same_object?(object, false) ||
          object.is_a?(Symbol) || object.is_a?(Integer)
      rescue StandardError
        false
      end

      # @param left [Object] a callback.
      # @param right [Object] another callback.
      # @return [Boolean] true when both condition lists hold the same objects,
      #   in order.
      def self.same_conditions?(left, right)
        left_if, left_unless = conditions(left)
        right_if, right_unless = conditions(right)
        same_list?(left_if, right_if) && same_list?(left_unless, right_unless)
      end

      # The conditions `skip_callback` appended after `parent`'s. {merged_from?}
      # has already required `parent`'s conditions to be a prefix.
      #
      # @param entry [Object] the merged subclass callback.
      # @param parent [Object] the ancestor callback it was merged from.
      # @return [Array(Array, Array)] the extra `if` conditions and the extra
      #   `unless` conditions.
      def self.extra_conditions(entry, parent)
        entry_if, entry_unless = conditions(entry)
        parent_if, parent_unless = conditions(parent)
        [entry_if.drop(parent_if.size), entry_unless.drop(parent_unless.size)]
      end

      # The `name` and `config` `ActiveSupport::Callbacks::Callback.build` reads
      # off a chain. {chain_view} builds one from a callback.
      ChainView = Struct.new(:name, :config)

      # @param callback [Object] an ActiveSupport callback.
      # @return [ChainView] that callback's chain name and config.
      def self.chain_view(callback)
        ChainView.new(callback.name, callback.chain_config)
      end

      # @param list [Array]
      # @param parent [Array]
      # @return [Boolean] true when `list` and `parent` are the same objects, in order.
      def self.same_list?(list, parent)
        list.size == parent.size && prefix?(list, parent)
      end

      # @param list [Array]
      # @param parent [Array] the objects `list` must start with.
      # @return [Boolean] true when each of `parent` is that object of `list`.
      #   A shorter `list` does not start with `parent`.
      def self.prefix?(list, parent)
        parent.each_with_index.all? { |item, index| same_object?(list[index], item) }
      end

      # `BasicObject#equal?`, so a proxy condition cannot answer for its target.
      # A condition that cannot be compared does not count as the parent's.
      #
      # @param left [Object]
      # @param right [Object]
      # @return [Boolean]
      def self.same_object?(left, right)
        SAME_OBJECT.bind_call(left, right)
      rescue StandardError
        false
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
      #   skipped.
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
      #   captured equivalent values. A block with no source, such as
      #   `&:save` or `method(:x).to_proc`, matches only itself.
      def self.same_block?(left, right, reloaded, same)
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
      # not run. The source file and the mutant file count as one file, and
      # their lines are left out, because a mutant can move lines.
      #
      # @param block [Proc]
      # @param reloaded [Array<String>] real paths of the source and mutant files.
      # @return [Array]
      def self.block_key(block, reloaded)
        file, line = block.source_location
        # CRuby only; elsewhere blocks match by file and line alone.
        label = RubyVM::InstructionSequence.of(block)&.label if defined?(::RubyVM::InstructionSequence)
        reloaded.include?(file && real_path(file)) ? [:reloaded, label] : [file, line, label]
      end

      # What two entries share when they are copies of one macro call, apart
      # from its arguments. A callback that names a method matches the same
      # name. A block or lambda matches by {.block_key}. A validator matches by
      # class and attributes.
      #
      # @param callback [Object] an ActiveSupport callback.
      # @param reloaded [Array<String>] real paths of the source and mutant files.
      # @return [Array]
      def self.key(callback, reloaded)
        filter = callback.filter
        filter_key = case filter
                     when Symbol, Module then filter
                     when Proc then block_key(filter, reloaded)
                     else [filter.class, filter.respond_to?(:attributes) ? filter.attributes : nil]
                     end
        [callback.kind, filter_key]
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
