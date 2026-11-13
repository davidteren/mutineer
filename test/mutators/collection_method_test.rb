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
      ["while condition", <<~RUBY, [%w[each map]], 0],
        def m
          while users.each { |user| user.notify }
            work
          end
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
      ["select stays when its array is discarded", <<~RUBY, [%w[select reject]], 0],
        def m
          xs.select { |item| item }
          :done
        end
      RUBY
      ["reject stays when its array is discarded", <<~RUBY, [%w[reject select]], 0],
        def m
          xs.reject { |item| item }
          :done
        end
      RUBY
      ["first stays when its value is discarded", <<~RUBY, [%w[first last]], 0],
        def m
          xs.first
          :done
        end
      RUBY
      ["last stays when its value is discarded", <<~RUBY, [%w[last first]], 0],
        def m
          xs.last
          :done
        end
      RUBY
      ["min stays when its value is discarded", <<~RUBY, [%w[min max]], 0],
        def m
          xs.min
          :done
        end
      RUBY
      ["max stays when its value is discarded", <<~RUBY, [%w[max min]], 0],
        def m
          xs.max
          :done
        end
      RUBY
    ]
  end
end
