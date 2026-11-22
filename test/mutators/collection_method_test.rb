# frozen_string_literal: true

require_relative "../test_helper"

class CollectionMethodTest < Minitest::Test
  def subject_for(source)
    def_node = Mutineer::Parser.parse_string(source).value.statements.body.first
    Mutineer::Subject.new(file: "snippet.rb", namespace: [], name: def_node.name,
                          singleton: false, def_node: def_node)
  end

  def run_mutator(body)
    source = "def m\n  #{body}\nend\n"
    [Mutineer::Mutators::CollectionMethod.new.mutations_for(subject_for(source), source), source]
  end

  def assert_single(body, original, replacement)
    mutations, source = run_mutator(body)
    assert_equal 1, mutations.size, "expected 1 mutation for #{body.inspect}"
    m = mutations.first
    assert_equal original, source[m.start_offset...m.end_offset]
    assert_equal replacement, m.replacement
    assert_equal :collection_method, m.operator
    assert m.valid?(source), "mutated source should re-parse"
  end

  def test_map_to_each     = assert_single("xs.map { |a| a }", "map", "each")
  def test_each_to_map     = assert_single("xs.each { |a| a }", "each", "map")
  def test_all_to_any      = assert_single("xs.all? { |a| a }", "all?", "any?")
  def test_any_to_all      = assert_single("xs.any? { |a| a }", "any?", "all?")
  def test_first_to_last   = assert_single("xs.first", "first", "last")
  def test_last_to_first   = assert_single("xs.last", "last", "first")
  def test_min_to_max      = assert_single("xs.min", "min", "max")
  def test_max_to_min      = assert_single("xs.max", "max", "min")
  def test_select_to_reject = assert_single("xs.select { |a| a }", "select", "reject")
  def test_reject_to_select = assert_single("xs.reject { |a| a }", "reject", "select")

  def test_unmapped_method_yields_none
    mutations, = run_mutator("xs.size")
    assert_empty mutations
  end

  def test_include_not_swapped
    mutations, = run_mutator("xs.include?(a)")
    assert_empty mutations
  end

  # Issue #436: a loop whose value is thrown away cannot be told from `map`.
  def test_each_to_map_skipped_when_another_statement_follows
    source = <<~RUBY
      def notify_all(users)
        users.each { |user| user.notify }
        users.size
      end
    RUBY
    swaps, declined = swaps_for(source)

    assert_empty swaps
    assert_equal 1, declined
  end

  # The rule, across the positions where a value is discarded or kept.
  # Each row is [label, source, expected [original, replacement] pairs, declined].
  def test_each_and_map_follow_whether_the_result_is_used
    cases.each do |label, source, expected, declined|
      swaps, count = swaps_for(source)
      assert_equal expected, swaps, label
      assert_equal declined, count, label
    end
  end

  private

  def swaps_for(source)
    operator = Mutineer::Mutators::CollectionMethod.new
    mutations = operator.mutations_for(subject_for(source), source)
    mutations.each do |mutation|
      assert_equal :collection_method, mutation.operator
      assert mutation.valid?(source), "mutated source should re-parse"
    end
    pairs = mutations.map { |mutation| [source[mutation.start_offset...mutation.end_offset], mutation.replacement] }
    [pairs, operator.declined]
  end

  # Positions the syntax tree can see without knowing the receiver's class.
  def cases
    [
      ["map statement before another", <<~RUBY, [], 1],
        def m
          users.map { |user| user.notify }
          users.size
        end
      RUBY
      ["each without a block, before another statement", <<~RUBY, [], 1],
        def m
          users.each
          :done
        end
      RUBY
      ["map without a block, before another statement", <<~RUBY, [], 1],
        def m
          users.map
          :done
        end
      RUBY
      ["each is not the last line of a block", <<~RUBY, [%w[map each]], 1],
        def m
          xs.map do |x|
            users.each { |user| user.notify }
            x
          end
        end
      RUBY
      ["if branch whose value is discarded", <<~RUBY, [], 1],
        def m
          if cond
            users.each { |user| user.notify }
          end
          :done
        end
      RUBY
      ["modifier if whose value is discarded", <<~RUBY, [], 1],
        def m
          users.each { |user| user.notify } if cond
          :done
        end
      RUBY
      ["modifier unless whose value is discarded", <<~RUBY, [], 1],
        def m
          users.each { |user| user.notify } unless cond
          :done
        end
      RUBY
      ["ternary whose value is discarded", <<~RUBY, [], 1],
        def m
          cond ? users.each { |user| user.notify } : []
          :done
        end
      RUBY
      ["while body", <<~RUBY, [], 1],
        def m
          while cond
            users.each { |user| user.notify }
          end
        end
      RUBY
      ["until body", <<~RUBY, [], 1],
        def m
          until cond
            users.each { |user| user.notify }
          end
        end
      RUBY
      ["for body is discarded because for returns the collection", <<~RUBY, [], 1],
        def m
          for user in users
            items.each { |item| item.touch }
          end
        end
      RUBY
      ["modifier while body", <<~RUBY, [], 1],
        def m
          users.each { |user| user.notify } while cond
        end
      RUBY
      ["ensure body", <<~RUBY, [], 1],
        def m
          work
        ensure
          users.each { |user| user.notify }
        end
      RUBY
      ["ensure inside a block whose result is used", <<~RUBY, [%w[map each]], 1],
        def m
          xs.map do
            work
          ensure
            users.each { |user| user.notify }
          end
        end
      RUBY
      ["not the last line of begin", <<~RUBY, [], 1],
        def m
          begin
            users.each { |user| user.notify }
            1
          end
        end
      RUBY
      ["not the last line of rescue", <<~RUBY, [], 1],
        def m
          work
        rescue
          users.each { |user| user.notify }
          nil
        end
      RUBY
      ["case branch whose value is discarded", <<~RUBY, [], 1],
        def m
          case x
          when 1
            users.each { |user| user.notify }
          end
          :done
        end
      RUBY
      ["not the last line inside parentheses", <<~RUBY, [], 1],
        def m
          (
            users.each { |user| user.notify }
            1
          )
        end
      RUBY
      ["element of a discarded array", <<~RUBY, [], 1],
        def m
          [users.each { |user| user.notify }]
          :done
        end
      RUBY
      ["value of a discarded hash", <<~RUBY, [], 1],
        def m
          { k: users.each { |user| user.notify } }
          :done
        end
      RUBY
      ["key of a discarded hash is still hashed", <<~RUBY, [%w[each map]], 0],
        def m
          { users.each { |user| user.notify } => 1 }
          :done
        end
      RUBY
      ["later rescue clause of a discarded begin", <<~RUBY, [], 2],
        def m
          begin
            work
          rescue A
            users.each { |user| user.notify }
          rescue B
            groups.each { |group| group.notify }
          end
          :done
        end
      RUBY
      ["later rescue clause of a returned begin", <<~RUBY, [%w[each map], %w[each map]], 0],
        def m
          begin
            work
          rescue A
            users.each { |user| user.notify }
          rescue B
            groups.each { |group| group.notify }
          end
        end
      RUBY
      # Prism 2 has no RescueNode#consequent; this row reaches that branch.
      ["rescue exception list is evaluated", <<~RUBY, [%w[map each], %w[each map]], 0],
        def m
          begin
            work
          rescue *errors.map { |error| error }
            nil
          rescue others.each { |error| error }
            nil
          end
          :done
        end
      RUBY
      ["discarded string interpolation still calls to_s", <<~RUBY, [%w[each map]], 0],
        def m
          "\#{users.each { |user| user.notify }}"
          :done
        end
      RUBY
      ["discarded symbol interpolation still calls to_s", <<~RUBY, [%w[each map]], 0],
        def m
          :"\#{users.each { |user| user.notify }}"
          :done
        end
      RUBY
      ["endpoint of a discarded range", <<~RUBY, [], 1],
        def m
          (users.each { |user| user.notify })..1
          :done
        end
      RUBY
      ["operand of a discarded &&", <<~RUBY, [], 1],
        def m
          users.each { |user| user.notify } && extra
          :done
        end
      RUBY
      ["operand of a discarded and", <<~RUBY, [], 1],
        def m
          users.each { |user| user.notify } and extra
          :done
        end
      RUBY
      ["operand of a discarded ||", <<~RUBY, [], 1],
        def m
          users.each { |user| user.notify } || extra
          :done
        end
      RUBY
      ["argument of defined?", <<~RUBY, [], 1],
        def m
          defined?(users.each { |user| user.notify })
        end
      RUBY
      ["interpolation inside defined? is not evaluated", <<~RUBY, [], 1],
        def m
          defined?(`echo \#{users.map { |user| user.name }}`)
        end
      RUBY
      ["regexp inside defined? is not evaluated", <<~RUBY, [], 1],
        def m
          defined?(/\#{users.map { |user| user.name }}/)
        end
      RUBY
      ["string inside defined? is not evaluated", <<~RUBY, [], 1],
        def m
          defined?("\#{users.each { |user| user.notify }}")
        end
      RUBY
      ["lazy chain inside defined? is not evaluated", <<~RUBY, [], 1],
        def m
          defined?(xs.lazy.each { |item| item.touch })
        end
      RUBY
      ["hash key inside defined? is not evaluated", <<~RUBY, [], 1],
        def m
          defined?({ users.each { |user| user.notify } => 1 })
        end
      RUBY
      ["earlier statement inside a command is discarded", <<~RUBY, [%w[map each]], 1],
        def m
          `echo \#{
            users.each { |user| user.notify }
            groups.map { |group| group.name }
          }`
          :done
        end
      RUBY
      ["not the last line of a singleton class", <<~RUBY, [], 1],
        def m
          class << obj
            users.each { |user| user.notify }
            1
          end
        end
      RUBY
      ["singleton class whose value is discarded", <<~RUBY, [], 1],
        def m
          class << obj
            users.each { |user| user.notify }
          end
          :done
        end
      RUBY
      ["not the last line of a lambda", <<~RUBY, [], 1],
        def m
          -> {
            users.each { |user| user.notify }
            1
          }
        end
      RUBY
      ["rescue modifier whose value is discarded", <<~RUBY, [], 1],
        def m
          users.each { |user| user.notify } rescue nil
          :done
        end
      RUBY
      ["nested if whose value is discarded", <<~RUBY, [], 1],
        def m
          if cond
            if other
              users.each { |user| user.notify }
            end
          end
          :done
        end
      RUBY
      ["two discarded loops", <<~RUBY, [], 2],
        def m
          users.each { |user| user.notify }
          groups.each { |group| group.notify }
          :done
        end
      RUBY
      ["inner loop is not last, outer loop is the return", <<~RUBY, [%w[each map]], 1],
        def m
          users.each do |user|
            items.each { |item| item.touch }
            user.notify
          end
        end
      RUBY
      ["chained each, outer statement discarded", <<~RUBY, [%w[each map]], 1],
        def m
          users.each { |user| user.notify }.each { |user| user.save }
          :done
        end
      RUBY
      ["not the last line of an argument begin", <<~RUBY, [], 1],
        def m
          foo(begin
            users.each { |user| user.notify }
            1
          end)
        end
      RUBY

      ["last expression of the method", <<~RUBY, [%w[each map]], 0],
        def m
          users.each { |user| user.notify }
        end
      RUBY
      ["last expression is map", <<~RUBY, [%w[map each]], 0],
        def m
          users.map { |user| user.name }
        end
      RUBY
      ["endless method", <<~RUBY, [%w[each map]], 0],
        def m = users.each { |user| user.notify }
      RUBY
      ["assignment, then another statement", <<~RUBY, [%w[each map]], 0],
        def m
          found = users.each { |user| user.notify }
          found
        end
      RUBY
      ["ivar assignment", <<~RUBY, [%w[each map]], 0],
        def m
          @found = users.each { |user| user.notify }
          :done
        end
      RUBY
      ["operator assignment", <<~RUBY, [%w[each map]], 0],
        def m
          found += users.each { |user| user.notify }
          :done
        end
      RUBY
      ["or-assignment", <<~RUBY, [%w[each map]], 0],
        def m
          found ||= users.each { |user| user.notify }
          :done
        end
      RUBY
      ["multiple assignment", <<~RUBY, [%w[each map]], 0],
        def m
          first, rest = users.each { |user| user.notify }
          :done
        end
      RUBY
      ["pattern match assigns the value", <<~RUBY, [%w[each map]], 0],
        def m
          users.each { |user| user.notify } => found
          :done
        end
      RUBY
      ["argument, then another statement", <<~RUBY, [%w[each map]], 0],
        def m
          foo(users.each { |user| user.notify })
          :done
        end
      RUBY
      ["keyword argument", <<~RUBY, [%w[each map]], 0],
        def m
          foo(list: users.each { |user| user.notify })
          :done
        end
      RUBY
      ["splat argument", <<~RUBY, [%w[each map]], 0],
        def m
          foo(*users.each { |user| user.notify })
          :done
        end
      RUBY
      ["block argument", <<~RUBY, [%w[each map]], 0],
        def m
          foo(&users.each { |user| user.notify })
          :done
        end
      RUBY
      ["begin passed as an argument", <<~RUBY, [%w[each map]], 0],
        def m
          foo(begin
            users.each { |user| user.notify }
          end)
          :done
        end
      RUBY
      ["discarded backtick still runs the command", <<~RUBY, [%w[map each]], 0],
        def m
          `echo \#{users.map { |user| user.name }}`
          :done
        end
      RUBY
      ["discarded %x still runs the command", <<~RUBY, [%w[map each]], 0],
        def m
          %x{echo \#{users.map { |user| user.name }}}
          :done
        end
      RUBY
      ["discarded regexp is still compiled", <<~RUBY, [%w[map each]], 0],
        def m
          /\#{users.map { |user| user.name }}/
          :done
        end
      RUBY
      ["discarded %r is still compiled", <<~RUBY, [%w[map each]], 0],
        def m
          %r{\#{users.map { |user| user.name }}}
          :done
        end
      RUBY
      ["lazy each still runs the block", <<~RUBY, [%w[each map]], 0],
        def m
          xs.lazy.each { |item| item.touch }
          :done
        end
      RUBY
      ["lazy map does not run the block", <<~RUBY, [%w[map each]], 0],
        def m
          xs.lazy.map { |item| item.touch }
          :done
        end
      RUBY
      ["each after a lazy map still runs the block", <<~RUBY, [%w[each map], %w[map each]], 0],
        def m
          xs.lazy.map { |item| item.name }.each { |item| item.touch }
          :done
        end
      RUBY
      ["chained call, then another statement", <<~RUBY, [%w[each map]], 0],
        def m
          users.each { |user| user.notify }.size
          :done
        end
      RUBY
      ["unary call on the result", <<~RUBY, [%w[each map]], 0],
        def m
          !users.each { |user| user.notify }
          :done
        end
      RUBY
      ["setter argument", <<~RUBY, [%w[each map]], 0],
        def m
          record.list = users.each { |user| user.notify }
          :done
        end
      RUBY
      ["index assignment", <<~RUBY, [%w[each map]], 0],
        def m
          record[key] = users.each { |user| user.notify }
          :done
        end
      RUBY
      ["last line of a block, outer loop discarded", <<~RUBY, [%w[each map]], 1],
        def m
          users.each do |user|
            items.each { |item| item.touch }
          end
          :done
        end
      RUBY
      ["last line of a block whose result is returned", <<~RUBY, [%w[map each], %w[each map]], 0],
        def m
          xs.map { users.each { |user| user.notify } }
        end
      RUBY
      ["explicit return", <<~RUBY, [%w[each map]], 0],
        def m
          return users.each { |user| user.notify }
          :dead
        end
      RUBY
      ["break value", <<~RUBY, [%w[each map], %w[each map]], 0],
        def m
          xs.each { break users.each { |user| user.notify } }
        end
      RUBY
      ["next value", <<~RUBY, [%w[map each], %w[each map]], 0],
        def m
          xs.map { next users.each { |user| user.notify } }
        end
      RUBY
      ["if branch is the return value", <<~RUBY, [%w[each map]], 0],
        def m
          if cond
            users.each { |user| user.notify }
          else
            []
          end
        end
      RUBY
      ["modifier if is the return value", <<~RUBY, [%w[each map]], 0],
        def m
          users.each { |user| user.notify } if cond
        end
      RUBY
      ["ternary is the return value", <<~RUBY, [%w[each map]], 0],
        def m
          cond ? users.each { |user| user.notify } : []
        end
      RUBY
      ["unless body is the return value", <<~RUBY, [%w[each map]], 0],
        def m
          unless cond
            users.each { |user| user.notify }
          end
        end
      RUBY
      ["right side of && is the return value", <<~RUBY, [%w[each map]], 0],
        def m
          flag && users.each { |user| user.notify }
        end
      RUBY
      ["left side of || is the return value", <<~RUBY, [%w[each map]], 0],
        def m
          users.each { |user| user.notify } || extra
        end
      RUBY
      ["for collection", <<~RUBY, [%w[each map]], 0],
        def m
          for user in users.each { |item| item }
            work
          end
        end
      RUBY
      ["begin is the return value", <<~RUBY, [%w[each map]], 0],
        def m
          begin
            users.each { |user| user.notify }
          end
        end
      RUBY
      ["rescue body is the return value", <<~RUBY, [%w[each map]], 0],
        def m
          work
        rescue
          users.each { |user| user.notify }
        end
      RUBY
      ["else body is the return value", <<~RUBY, [%w[each map]], 0],
        def m
          begin
            work
          rescue
            nil
          else
            users.each { |user| user.notify }
          end
        end
      RUBY
      ["method body kept when ensure follows", <<~RUBY, [%w[each map]], 0],
        def m
          users.each { |user| user.notify }
        ensure
          cleanup
        end
      RUBY
      ["rescue modifier is the return value", <<~RUBY, [%w[each map]], 0],
        def m
          users.each { |user| user.notify } rescue nil
        end
      RUBY
      ["case branch is the return value", <<~RUBY, [%w[each map]], 0],
        def m
          case x
          when 1
            users.each { |user| user.notify }
          end
        end
      RUBY
      ["case predicate", <<~RUBY, [%w[each map]], 0],
        def m
          case users.each { |user| user.notify }
          when 1
            0
          end
        end
      RUBY
      ["when argument", <<~RUBY, [%w[each map]], 0],
        def m
          case x
          when users.each { |user| user.notify }
            0
          end
        end
      RUBY
      ["array is the return value", <<~RUBY, [%w[each map]], 0],
        def m
          [users.each { |user| user.notify }]
        end
      RUBY
      ["interpolation is the return value", <<~RUBY, [%w[each map]], 0],
        def m
          "\#{users.each { |user| user.notify }}"
        end
      RUBY
      ["parentheses are the return value", <<~RUBY, [%w[each map]], 0],
        def m
          (users.each { |user| user.notify })
        end
      RUBY
      ["singleton class is the return value", <<~RUBY, [%w[each map]], 0],
        def m
          class << obj
            users.each { |user| user.notify }
          end
        end
      RUBY
      ["singleton class object", <<~RUBY, [%w[each map]], 0],
        def m
          class << users.each { |user| user.notify }
            1
          end
          :done
        end
      RUBY
      ["last line of a lambda", <<~RUBY, [%w[each map]], 0],
        def m
          -> { users.each { |user| user.notify } }
        end
      RUBY
      ["block parameter default", <<~RUBY, [%w[map each], %w[each map]], 0],
        def m
          xs.map { |item = users.each { |user| user.notify }| item }
        end
      RUBY
      ["all? stays when its boolean is discarded", <<~RUBY, [%w[all? any?]], 0],
        def m
          xs.all? { |item| item }
          :done
        end
      RUBY
      ["any? stays when its boolean is discarded", <<~RUBY, [%w[any? all?]], 0],
        def m
          xs.any? { |item| item }
          :done
        end
      RUBY
      ["select is declined when its value is discarded", <<~RUBY, [], 1],
        def m
          xs.select { |item| item }
          :done
        end
      RUBY
      ["select stays when its value is the return value", <<~RUBY, [%w[select reject]], 0],
        def m
          xs.select { |item| item }
        end
      RUBY
      ["reject is declined when its value is discarded", <<~RUBY, [], 1],
        def m
          xs.reject { |item| item }
          :done
        end
      RUBY
      ["reject stays when its value is the return value", <<~RUBY, [%w[reject select]], 0],
        def m
          xs.reject { |item| item }
        end
      RUBY
      ["first is declined when its value is discarded", <<~RUBY, [], 1],
        def m
          xs.first
          :done
        end
      RUBY
      ["first stays when its value is the return value", <<~RUBY, [%w[first last]], 0],
        def m
          xs.first
        end
      RUBY
      ["last is declined when its value is discarded", <<~RUBY, [], 1],
        def m
          xs.last
          :done
        end
      RUBY
      ["last stays when its value is the return value", <<~RUBY, [%w[last first]], 0],
        def m
          xs.last
        end
      RUBY
      ["min is declined when its value is discarded", <<~RUBY, [], 1],
        def m
          xs.min
          :done
        end
      RUBY
      ["min stays when its value is the return value", <<~RUBY, [%w[min max]], 0],
        def m
          xs.min
        end
      RUBY
      ["max is declined when its value is discarded", <<~RUBY, [], 1],
        def m
          xs.max
          :done
        end
      RUBY
      ["max stays when its value is the return value", <<~RUBY, [%w[max min]], 0],
        def m
          xs.max
        end
      RUBY
      ["select stays when assigned", <<~RUBY, [%w[select reject]], 0],
        def m
          found = xs.select { |item| item }
          :done
        end
      RUBY
      ["first stays as a condition", <<~RUBY, [%w[first last]], 0],
        def m
          if xs.first
            work
          end
          :done
        end
      RUBY
      ["min with a block stays when discarded", <<~RUBY, [%w[min max]], 0],
        def m
          xs.min { |a, b| log(a) <=> b }
          :done
        end
      RUBY
      ["max with a block stays when discarded", <<~RUBY, [%w[max min]], 0],
        def m
          xs.max { |a, b| log(a) <=> b }
          :done
        end
      RUBY
      ["lazy first stays when discarded", <<~RUBY, [%w[first last]], 0],
        def m
          xs.lazy.first
          :done
        end
      RUBY
      ["all? and any? stay in the same body", <<~RUBY, [%w[all? any?], %w[any? all?]], 1],
        def m
          xs.all? { |item| item }
          xs.any? { |item| item }
          xs.first
          :done
        end
      RUBY
      ["lazy local each still runs the block", <<~RUBY, [%w[each map]], 0],
        def m
          enum = xs.lazy
          enum.each { |item| item.touch }
          :done
        end
      RUBY
      ["lazy local map does not run the block", <<~RUBY, [%w[map each]], 0],
        def m
          enum = xs.lazy
          enum.map { |item| item.touch }
          :done
        end
      RUBY
      ["lazy local from a longer chain", <<~RUBY, [%w[map each], %w[each map]], 0],
        def m
          enum = xs.lazy.map { |item| item.name }
          enum.each { |item| item.touch }
          :done
        end
      RUBY
      ["lazy local chain after the variable", <<~RUBY, [%w[each map], %w[map each]], 0],
        def m
          enum = xs.lazy
          enum.map { |item| item.name }.each { |item| item.touch }
          :done
        end
      RUBY
      ["lazy local assigned with ||=", <<~RUBY, [%w[each map]], 0],
        def m
          enum ||= xs.lazy
          enum.each { |item| item.touch }
          :done
        end
      RUBY
      ["lazy local copied to another local", <<~RUBY, [%w[each map]], 0],
        def m
          enum = xs.lazy
          other = enum
          other.each { |item| item.touch }
          :done
        end
      RUBY
      ["lazy local read in a condition", <<~RUBY, [%w[each map]], 0],
        def m
          enum = xs.lazy
          if enum.each { |item| item.touch }
            work
          end
          :done
        end
      RUBY
      ["local not assigned from lazy is declined", <<~RUBY, [], 1],
        def m
          enum = xs.to_a
          enum.each { |item| item.touch }
          :done
        end
      RUBY
      ["another local holds the lazy enumerator", <<~RUBY, [], 1],
        def m
          enum = xs.lazy
          list = xs.to_a
          list.each { |item| item.touch }
          :done
        end
      RUBY
      ["instance variable is not known to be lazy", <<~RUBY, [], 1],
        def m
          @items.each { |item| item.touch }
          :done
        end
      RUBY
      ["if condition is truthiness only", <<~RUBY, [], 1],
        def m
          if users.each { |user| user.notify }
            work
          end
          :done
        end
      RUBY
      ["unless condition is truthiness only", <<~RUBY, [], 1],
        def m
          unless users.each { |user| user.notify }
            work
          end
          :done
        end
      RUBY
      ["while condition is truthiness only", <<~RUBY, [], 1],
        def m
          while users.each { |user| user.notify }
            work
          end
          :done
        end
      RUBY
      ["until condition is truthiness only", <<~RUBY, [], 1],
        def m
          until users.each { |user| user.notify }
            work
          end
          :done
        end
      RUBY
      ["map in an if condition is truthiness only", <<~RUBY, [], 1],
        def m
          if users.map { |user| user.name }
            work
          end
          :done
        end
      RUBY
      ["elsif condition is truthiness only", <<~RUBY, [], 1],
        def m
          if cond
            work
          elsif users.each { |user| user.notify }
            more
          end
          :done
        end
      RUBY
      ["modifier if condition", <<~RUBY, [], 1],
        def m
          work if users.each { |user| user.notify }
          :done
        end
      RUBY
      ["ternary condition", <<~RUBY, [], 1],
        def m
          users.each { |user| user.notify } ? 1 : 2
        end
      RUBY
      ["while condition as the method value", <<~RUBY, [], 1],
        def m
          while users.each { |user| user.notify }
            work
          end
        end
      RUBY
      ["left of && with the result kept", <<~RUBY, [], 1],
        def m
          users.each { |user| user.notify } && extra
        end
      RUBY
      ["left of and with the result kept", <<~RUBY, [], 1],
        def m
          users.each { |user| user.notify } and extra
        end
      RUBY
      ["left of && assigned", <<~RUBY, [], 1],
        def m
          ok = users.each { |user| user.notify } && extra
          :done
        end
      RUBY
      ["left of or stays when the result is kept", <<~RUBY, [%w[each map]], 0],
        def m
          users.each { |user| user.notify } or extra
        end
      RUBY
      ["each in a condition with a call on its result", <<~RUBY, [%w[each map]], 0],
        def m
          if users.each { |user| user.notify }.empty?
            work
          end
          :done
        end
      RUBY
      ["negated condition keeps the swap", <<~RUBY, [%w[each map]], 0],
        def m
          if !users.each { |user| user.notify }
            work
          end
          :done
        end
      RUBY
      ["lazy each in a condition", <<~RUBY, [%w[each map]], 0],
        def m
          if xs.lazy.each { |item| item.touch }
            work
          end
          :done
        end
      RUBY
      ["case without a subject, when condition", <<~RUBY, [], 1],
        def m
          case
          when users.each { |user| user.notify }
            1
          end
          :done
        end
      RUBY
      ["case with a subject keeps a when value", <<~RUBY, [%w[each map]], 0],
        def m
          case x
          when users.each { |user| user.notify }
            1
          end
          :done
        end
      RUBY
      ["if branch is the return value, not a condition", <<~RUBY, [%w[each map]], 0],
        def m
          if cond
            users.each { |user| user.notify }
          end
        end
      RUBY
      ["each in a condition is truthiness only", <<~RUBY, [], 1],
        def m
          if users.each { |u| u }
            work
          end
          :done
        end
      RUBY
      ["each on the right of && in a condition", <<~RUBY, [], 1],
        def m
          if a && users.each { |u| u }
            work
          end
          :done
        end
      RUBY
      ["each in parentheses in a condition", <<~RUBY, [], 1],
        def m
          if (users.each { |u| u })
            work
          end
          :done
        end
      RUBY
      ["each on the left of || in a condition", <<~RUBY, [], 1],
        def m
          if users.each { |u| u } || a
            work
          end
          :done
        end
      RUBY
      ["each on the right of || in an unless condition", <<~RUBY, [], 1],
        def m
          unless a || users.each { |u| u }
            work
          end
          :done
        end
      RUBY
      ["each in a nested && and || in a while condition", <<~RUBY, [], 1],
        def m
          while a && (b || users.each { |u| u })
            work
          end
          :done
        end
      RUBY
      ["each on the right of && with the result kept", <<~RUBY, [%w[each map]], 0],
        def m
          ok = a && users.each { |u| u }
          :done
        end
      RUBY
      ["each on the left of || with the result kept", <<~RUBY, [%w[each map]], 0],
        def m
          ok = users.each { |u| u } || a
          :done
        end
      RUBY
      ["each in a condition with a call on its result", <<~RUBY, [%w[each map]], 0],
        def m
          if users.each { |u| u }.empty?
            work
          end
          :done
        end
      RUBY
      ["map in a condition is truthiness only", <<~RUBY, [], 1],
        def m
          if users.map { |u| u }
            work
          end
          :done
        end
      RUBY
      ["map on the right of && in a condition", <<~RUBY, [], 1],
        def m
          if a && users.map { |u| u }
            work
          end
          :done
        end
      RUBY
      ["map in parentheses in a condition", <<~RUBY, [], 1],
        def m
          if (users.map { |u| u })
            work
          end
          :done
        end
      RUBY
      ["map on the left of || in a condition", <<~RUBY, [], 1],
        def m
          if users.map { |u| u } || a
            work
          end
          :done
        end
      RUBY
      ["map on the right of || in an unless condition", <<~RUBY, [], 1],
        def m
          unless a || users.map { |u| u }
            work
          end
          :done
        end
      RUBY
      ["map in a nested && and || in a while condition", <<~RUBY, [], 1],
        def m
          while a && (b || users.map { |u| u })
            work
          end
          :done
        end
      RUBY
      ["map on the right of && with the result kept", <<~RUBY, [%w[map each]], 0],
        def m
          ok = a && users.map { |u| u }
          :done
        end
      RUBY
      ["map on the left of || with the result kept", <<~RUBY, [%w[map each]], 0],
        def m
          ok = users.map { |u| u } || a
          :done
        end
      RUBY
      ["map in a condition with a call on its result", <<~RUBY, [%w[map each]], 0],
        def m
          if users.map { |u| u }.empty?
            work
          end
          :done
        end
      RUBY
      ["select in a condition is truthiness only", <<~RUBY, [], 1],
        def m
          if xs.select { |u| u }
            work
          end
          :done
        end
      RUBY
      ["select on the right of && in a condition", <<~RUBY, [], 1],
        def m
          if a && xs.select { |u| u }
            work
          end
          :done
        end
      RUBY
      ["select in parentheses in a condition", <<~RUBY, [], 1],
        def m
          if (xs.select { |u| u })
            work
          end
          :done
        end
      RUBY
      ["select on the left of || in a condition", <<~RUBY, [], 1],
        def m
          if xs.select { |u| u } || a
            work
          end
          :done
        end
      RUBY
      ["select on the right of || in an unless condition", <<~RUBY, [], 1],
        def m
          unless a || xs.select { |u| u }
            work
          end
          :done
        end
      RUBY
      ["select in a nested && and || in a while condition", <<~RUBY, [], 1],
        def m
          while a && (b || xs.select { |u| u })
            work
          end
          :done
        end
      RUBY
      ["select on the right of && with the result kept", <<~RUBY, [%w[select reject]], 0],
        def m
          ok = a && xs.select { |u| u }
          :done
        end
      RUBY
      ["select on the left of || with the result kept", <<~RUBY, [%w[select reject]], 0],
        def m
          ok = xs.select { |u| u } || a
          :done
        end
      RUBY
      ["select in a condition with a call on its result", <<~RUBY, [%w[select reject]], 0],
        def m
          if xs.select { |u| u }.empty?
            work
          end
          :done
        end
      RUBY
      ["reject in a condition is truthiness only", <<~RUBY, [], 1],
        def m
          if xs.reject { |u| u }
            work
          end
          :done
        end
      RUBY
      ["reject on the right of && in a condition", <<~RUBY, [], 1],
        def m
          if a && xs.reject { |u| u }
            work
          end
          :done
        end
      RUBY
      ["reject in parentheses in a condition", <<~RUBY, [], 1],
        def m
          if (xs.reject { |u| u })
            work
          end
          :done
        end
      RUBY
      ["reject on the left of || in a condition", <<~RUBY, [], 1],
        def m
          if xs.reject { |u| u } || a
            work
          end
          :done
        end
      RUBY
      ["reject on the right of || in an unless condition", <<~RUBY, [], 1],
        def m
          unless a || xs.reject { |u| u }
            work
          end
          :done
        end
      RUBY
      ["reject in a nested && and || in a while condition", <<~RUBY, [], 1],
        def m
          while a && (b || xs.reject { |u| u })
            work
          end
          :done
        end
      RUBY
      ["reject on the right of && with the result kept", <<~RUBY, [%w[reject select]], 0],
        def m
          ok = a && xs.reject { |u| u }
          :done
        end
      RUBY
      ["reject on the left of || with the result kept", <<~RUBY, [%w[reject select]], 0],
        def m
          ok = xs.reject { |u| u } || a
          :done
        end
      RUBY
      ["reject in a condition with a call on its result", <<~RUBY, [%w[reject select]], 0],
        def m
          if xs.reject { |u| u }.empty?
            work
          end
          :done
        end
      RUBY
      ["select on the left of && with the result kept", <<~RUBY, [], 1],
        def m
          ok = xs.select { |u| u } && b
          :done
        end
      RUBY
      ["reject on the left of && as a statement", <<~RUBY, [], 1],
        def m
          xs.reject { |u| u } && b
          :done
        end
      RUBY
      ["select with arguments in a condition stays", <<~RUBY, [%w[select reject]], 0],
        def m
          if IO.select([reader], nil, nil, 1)
            work
          end
          :done
        end
      RUBY
      ["reject with arguments in a condition stays", <<~RUBY, [%w[reject select]], 0],
        def m
          if reject(a)
            work
          end
          :done
        end
      RUBY
      ["lazy select in an && condition stays", <<~RUBY, [%w[select reject]], 0],
        def m
          if a && xs.lazy.select { |u| u }
            work
          end
          :done
        end
      RUBY
      ["first in a nested condition stays", <<~RUBY, [%w[first last]], 0],
        def m
          if a && xs.first
            work
          end
          :done
        end
      RUBY
      ["while body is still discarded", <<~RUBY, [], 1],
        def m
          while cond
            users.each { |user| user.notify }
          end
          :done
        end
      RUBY
      ["IO.select stays when discarded", <<~RUBY, [%w[select reject]], 0],
        def m
          IO.select([reader], nil, nil, 1)
          :done
        end
      RUBY
      ["receiverless select with arguments stays", <<~RUBY, [%w[select reject]], 0],
        def m
          select([reader])
          :done
        end
      RUBY
      ["first on the left of || decides the right side", <<~RUBY, [%w[first last]], 0],
        def m
          xs.first || warn("empty")
          :done
        end
      RUBY
      ["last on the left of or decides the right side", <<~RUBY, [%w[last first]], 0],
        def m
          xs.last or return
          :done
        end
      RUBY
      ["min on the left of && decides the right side", <<~RUBY, [%w[min max]], 0],
        def m
          xs.min && work
          :done
        end
      RUBY
      ["each on the left of || is still declined when the || is discarded", <<~RUBY, [], 1],
        def m
          xs.each { |x| x } || work
          :done
        end
      RUBY
      ["min with a block argument stays when discarded", <<~RUBY, [%w[min max]], 0],
        def m
          xs.min(&order)
          :done
        end
      RUBY
      ["lazy local from a ternary", <<~RUBY, [%w[each map]], 0],
        def m
          enum = flag ? xs.lazy : xs
          enum.each { |item| item.touch }
          :done
        end
      RUBY
      ["lazy local from parentheses", <<~RUBY, [%w[each map]], 0],
        def m
          enum = (xs.lazy)
          enum.each { |item| item.touch }
          :done
        end
      RUBY
      ["lazy local from ||", <<~RUBY, [%w[each map]], 0],
        def m
          enum = xs.lazy || ys
          enum.each { |item| item.touch }
          :done
        end
      RUBY
      ["lazy local assigned with &&=", <<~RUBY, [%w[each map]], 0],
        def m
          enum &&= xs.lazy
          enum.each { |item| item.touch }
          :done
        end
      RUBY
      ["lazy local from multiple assignment", <<~RUBY, [%w[each map]], 0],
        def m
          enum, count = xs.lazy, 1
          enum.each { |item| item.touch }
          :done
        end
      RUBY
      ["lazy local assigned inside a block", <<~RUBY, [%w[each map]], 1],
        def m
          items.each do |item|
            enum = item.lazy
            enum.each { |entry| entry.touch }
            :seen
          end
          :done
        end
      RUBY
      ["lazy local from an unless expression", <<~RUBY, [%w[each map]], 0],
        def m
          enum = unless flag then xs.lazy else xs end
          enum.each { |item| item.touch }
          :done
        end
      RUBY
      ["local from an unless expression with no lazy", <<~RUBY, [], 1],
        def m
          enum = unless flag then xs else ys end
          enum.each { |item| item.touch }
          :done
        end
      RUBY
      ["first inside a chain of && decides the right side", <<~RUBY, [%w[first last]], 0],
        def m
          flag && xs.first && warn("hit")
          :done
        end
      RUBY
      ["first in parentheses on the left of || decides the right side", <<~RUBY, [%w[first last]], 0],
        def m
          (xs.first) || warn("empty")
          :done
        end
      RUBY
      ["first on the right of a discarded && stays, only a statement of its own is declined", <<~RUBY, [%w[first last]], 0],
        def m
          flag && warn("hit") && xs.first
          :done
        end
      RUBY
      ["lazy local from a chained assignment", <<~RUBY, [%w[each map]], 0],
        def m
          first = second = xs.lazy
          second.each { |item| item.touch }
          :done
        end
      RUBY
      ["lazy local from begin", <<~RUBY, [%w[each map]], 0],
        def m
          enum = begin xs.lazy end
          enum.each { |item| item.touch }
          :done
        end
      RUBY
      ["lazy local from a rescue modifier", <<~RUBY, [%w[each map]], 0],
        def m
          enum = xs.lazy rescue nil
          enum.each { |item| item.touch }
          :done
        end
      RUBY
      ["lazy local from a nested multiple assignment", <<~RUBY, [%w[each map]], 0],
        def m
          (enum, count), other = [xs.lazy, 1], 2
          enum.each { |item| item.touch }
          :done
        end
      RUBY
      ["first in a ternary on the left of || stays", <<~RUBY, [%w[first last]], 0],
        def m
          (flag ? xs.first : nil) || warn("empty")
          :done
        end
      RUBY
      ["first rescue modifier stays", <<~RUBY, [%w[first last]], 0],
        def m
          xs.first rescue nil
          :done
        end
      RUBY
      ["first inside defined? stays", <<~RUBY, [%w[first last]], 0],
        def m
          defined?(xs.first)
          :done
        end
      RUBY
      ["first as a modifier-if statement is declined", <<~RUBY, [], 1],
        def m
          xs.first if flag
          :done
        end
      RUBY
      ["lazy call inside a parenthesized receiver", <<~RUBY, [%w[each map]], 0],
        def m
          if (xs.lazy).each { |item| item.touch }
            work
          end
          :done
        end
      RUBY
      ["lazy local bound by a for index", <<~RUBY, [%w[each map]], 0],
        def m
          for lazy_list in [xs.lazy]
            lazy_list.each { |item| item.touch }
            :seen
          end
          :done
        end
      RUBY
      ["first in an else branch is declined", <<~RUBY, [], 1],
        def m
          if flag
            work
          else
            xs.first
          end
          :done
        end
      RUBY
      ["first in a case/in body is declined", <<~RUBY, [], 1],
        def m
          case value
          in Integer
            xs.first
          end
          :done
        end
      RUBY
      ["first in a case/when body is declined", <<~RUBY, [], 1],
        def m
          case value
          when 1
            xs.first
          end
          :done
        end
      RUBY
      ["reject with arguments stays", <<~RUBY, [%w[reject select]], 0],
        def m
          reject([reader])
          :done
        end
      RUBY
      ["lazy local bound by a multi-target for index", <<~RUBY, [%w[each map]], 0],
        def m
          for index, enum in [[1, xs.lazy]]
            enum.each { |item| item.touch }
            :seen
          end
          :done
        end
      RUBY
      ["lazy local after another value in multiple assignment", <<~RUBY, [%w[each map]], 0],
        def m
          count, enum = 1, xs.lazy
          enum.each { |item| item.touch }
          :done
        end
      RUBY
      ["min with forwarded arguments stays when discarded", <<~RUBY, [%w[min max]], 0],
        def m(...)
          xs.min(...)
          :done
        end
      RUBY
      ["first in a singleton class body is declined", <<~RUBY, [], 1],
        def m
          class << obj
            xs.first
            :x
          end
          :done
        end
      RUBY
    ]
  end
end
