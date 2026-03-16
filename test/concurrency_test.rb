require 'test_helper'

# Test Models:
#
#   Answer       - :scope => :question_id
#   Comment      - :scope => :question_id (with an AR default scope)
#   Invoice      - :scope => :account_id, :start_at => 1000
#   Product      - :scope => :account_id, :start_at => lambda { |r| r.computed_start_value }
#   Order        - :scope => :non_existent_column
#   User         - :scope => :account_id, :column => :custom_sequential_id
#   Address      - :scope => :account_id ('sequential_id' does not exist)
#   Email        - :scope => [:emailable_id, :emailable_type]
#   Subscription - no options
#   Rating       - :scope => :comment_id, skip: { |r| r.score == 0 }
#   Monster      - no options
#   Zombie       - STI, inherits from Monster
#   Werewolf     - STI, inherits from Monster

#   ConcurrentBadger - scope: :burrow_id,
#                      NOT NULL constraint on sequential_id,
#                      UNIQUE constraint on sequential_id within burrow_id scope
#   DeadlockAlpha    - no options
#   DeadlockBeta     - no options

if ENV['DB'] == 'postgresql'
  class ConcurrencyTest < ActiveSupport::TestCase
    self.use_transactional_tests = false

    Barrier = Struct.new(:size, :waiting, :mutex, :condition) do
      def initialize(size)
        super(size, 0, Mutex.new, ConditionVariable.new)
      end

      def wait
        mutex.synchronize do
          self.waiting += 1
          if waiting < size
            condition.wait(mutex)
          else
            condition.broadcast
          end
        end
      end
    end

    def setup
      cleanup_models.each(&:delete_all)
    end

    def teardown
      cleanup_models.each(&:delete_all)
    end

    test "creates records concurrently without data races" do
      range = (1..50)

      threads = range.map do
        Thread.new do
          with_connection do
            ConcurrentBadger.create!(burrow_id: 1)
          end
        end
      end

      threads.each(&:join)

      sequential_ids = ConcurrentBadger.order(:sequential_id).pluck(:sequential_id)
      assert_equal range.to_a, sequential_ids
    end

    test "does not affect saving multiple records within a transaction" do
      range = (1..10)

      ConcurrentBadger.transaction do
        range.each do
          ConcurrentBadger.create!(burrow_id: 1)
        end
      end

      sequential_ids = ConcurrentBadger.order(:sequential_id).pluck(:sequential_id)
      assert_equal range.to_a, sequential_ids
    end

    test "does not affect saving multiple records within nested transactons" do
      range = (1..10)

      ConcurrentBadger.transaction do
        ConcurrentBadger.transaction do
          ConcurrentBadger.transaction do
            range.each do
              ConcurrentBadger.create!(burrow_id: 1)
            end
          end
        end
      end

      sequential_ids = ConcurrentBadger.order(:sequential_id).pluck(:sequential_id)
      assert_equal range.to_a, sequential_ids
    end

    test "does not deadlock when transactions update different tables before allocating sequences" do
      alpha = DeadlockAlpha.create!(name: "seed alpha")
      beta = DeadlockBeta.create!(name: "seed beta")
      barrier = Barrier.new(2)
      errors = Queue.new

      threads = [
        Thread.new do
          with_connection do
            DeadlockAlpha.transaction do
              DeadlockBeta.find(beta.id).update!(name: "updated by alpha transaction")
              barrier.wait
              DeadlockAlpha.create!(name: "created by alpha transaction")
            end
          end
        rescue => error
          errors << error
        end,
        Thread.new do
          with_connection do
            DeadlockBeta.transaction do
              DeadlockAlpha.find(alpha.id).update!(name: "updated by beta transaction")
              barrier.wait
              DeadlockBeta.create!(name: "created by beta transaction")
            end
          end
        rescue => error
          errors << error
        end
      ]

      threads.each(&:join)

      assert_thread_errors!(errors)
      assert_equal [1, 2], DeadlockAlpha.order(:sequential_id).pluck(:sequential_id)
      assert_equal [1, 2], DeadlockBeta.order(:sequential_id).pluck(:sequential_id)
    end

    test "allocates independent sequences concurrently for separate scopes" do
      barrier = Barrier.new(2)
      errors = Queue.new

      threads = [1, 2].map do |burrow_id|
        Thread.new do
          with_connection do
            barrier.wait
            10.times { ConcurrentBadger.create!(burrow_id: burrow_id) }
          end
        rescue => error
          errors << error
        end
      end

      threads.each(&:join)

      assert_thread_errors!(errors)
      assert_equal (1..10).to_a, ConcurrentBadger.where(burrow_id: 1).order(:sequential_id).pluck(:sequential_id)
      assert_equal (1..10).to_a, ConcurrentBadger.where(burrow_id: 2).order(:sequential_id).pluck(:sequential_id)
    end

  private

    def cleanup_models
      [ConcurrentBadger, DeadlockAlpha, DeadlockBeta]
    end

    def with_connection(&block)
      ActiveRecord::Base.connection_pool.with_connection(&block)
    end

    def assert_thread_errors!(errors)
      return if errors.empty?

      error = errors.pop
      flunk("#{error.class}: #{error.message}\n#{Array(error.backtrace).join("\n")}")
    end
  end
end
