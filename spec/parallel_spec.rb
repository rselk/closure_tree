require 'spec_helper'

# We don't need to run the expensive parallel tests for every combination of prefix/suffix.
# Those affect SQL generation, not parallelism
def run_parallel_tests?
  ActiveRecord::Base.table_name_prefix.empty? &&
    ActiveRecord::Base.table_name_suffix.empty?
end

def max_threads
  5
end

class WorkerBase
  extend Forwardable
  attr_reader :name
  def_delegators :@thread, :join, :wakeup, :status, :to_s

  def initialize(target, name)
    @target = target
    @name = name
    @thread = Thread.new do
      ActiveRecord::Base.connection_pool.with_connection { before_work } if respond_to? :before_work
      puts "#{Thread.current} going to sleep..."
      sleep
      puts "#{Thread.current} woke up..."
      ActiveRecord::Base.connection_pool.with_connection { work }
      puts "#{Thread.current} done..."
    end
  end
end

class FindOrCreateWorker < WorkerBase
  def work
    path = [name, :a, :b, :c]
    puts "#{Thread.current} making #{path}..."
    t = (@target || Tag).find_or_create_by_path(path)
    puts "#{Thread.current} made #{t.id}, #{t.ancestry_path}"
  end
end

describe 'Concurrent creation' do
  before :each do
    @target = nil
    @iterations = 5
  end

  def run_workers(worker_class = FindOrCreateWorker)
    @names = @iterations.times.map { |iter| "iteration ##{iter}" }
    @names.each do |name|
      workers = max_threads.times.map { worker_class.new(@target, name) }
      # Wait for all the threads to get ready:
      while true
        unready_workers = workers.select { |ea| ea.status != 'sleep' }
        if unready_workers.empty?
          break
        else
          puts "Not ready to wakeup: #{unready_workers.map { |ea| [ea.to_s, ea.status] }}"
          sleep(0.1)
        end
      end
      sleep(0.25)
      # OK, GO!
      puts 'Calling .wakeup on all workers...'
      workers.each(&:wakeup)
      sleep(0.25)
      # Then wait for them to finish:
      puts 'Calling .join on all workers...'
      workers.each(&:join)
    end
    # Ensure we're still connected:
    ActiveRecord::Base.connection_pool.connection
  end

  it 'will not create dupes from class methods' do
    run_workers
    expect(Tag.roots.collect { |ea| ea.name }).to match_array(@names)
    # No dupe children:
    %w(a b c).each do |ea|
      expect(Tag.where(name: ea).size).to eq(@iterations)
    end
  end

  it 'will not create dupes from instance methods' do
    @target = Tag.create!(name: 'root')
    run_workers
    expect(@target.reload.children.collect { |ea| ea.name }).to match_array(@names)
    expect(Tag.where(name: @names).size).to eq(@iterations)
    %w(a b c).each do |ea|
      expect(Tag.where(name: ea).size).to eq(@iterations)
    end
  end

  it 'creates dupe roots without advisory locks' do
    # disable with_advisory_lock:
    allow(Tag).to receive(:with_advisory_lock) { |_lock_name, &block| block.call }
    run_workers
    # duplication from at least one iteration:
    expect(Tag.where(name: @names).size).to be > @iterations
  end unless sqlite? # sqlite throws errors from concurrent access

  class SiblingPrependerWorker < WorkerBase
    def before_work
      @target.reload
      @sibling = Label.new(name: SecureRandom.hex(10))
    end

    def work
      @target.prepend_sibling @sibling
    end
  end

  # TODO: this test should be rewritten to be proper producer-consumer code
  xit 'fails to deadlock from parallel sibling churn' do
    # target should be non-trivially long to maximize time spent in hierarchy maintenance
    target = Tag.find_or_create_by_path(('a'..'z').to_a + ('A'..'Z').to_a)
    expected_children = (1..100).to_a.map { |ea| "root ##{ea}" }
    children_to_add = expected_children.dup
    added_children = []
    children_to_delete = []
    deleted_children = []
    creator_threads = @workers.times.map do
      Thread.new do
        while children_to_add.present?
          name = children_to_add.shift
          unless name.nil?
            Tag.transaction { target.find_or_create_by_path(name) }
            children_to_delete << name
            added_children << name
          end
        end
      end
    end
    run_destruction = true
    destroyer_threads = @workers.times.map do
      Thread.new do
        begin
          victim_name = children_to_delete.shift
          if victim_name
            Tag.transaction do
              victim = target.children.where(name: victim_name).first
              victim.destroy
              deleted_children << victim_name
            end
          else
            sleep rand # wait for more victims
          end
        end while run_destruction || !children_to_delete.empty?
      end
    end
    creator_threads.each(&:join)
    destroyer_threads.each(&:join)
    expect(added_children).to match(expected_children)
    expect(deleted_children).to match(expected_children)
  end

  it 'fails to deadlock while simultaneously deleting items from the same hierarchy' do
    target = User.find_or_create_by_path((1..200).to_a.map { |ea| ea.to_s })
    emails = target.self_and_ancestors.to_a.map(&:email).shuffle
    Parallel.map(emails, :in_threads => max_threads) do |email|
      ActiveRecord::Base.connection_pool.with_connection do
        User.transaction do
          puts "Destroying #{email}..."
          User.where(email: email).destroy_all
        end
      end
    end
    User.connection.reconnect!
    expect(User.all).to be_empty
  end unless sqlite? # sqlite throws errors from concurrent access

  class SiblingPrependerWorker < WorkerBase
    def before_work
      @target.reload
      @sibling = Label.new(name: SecureRandom.hex(10))
    end

    def work
      @target.prepend_sibling @sibling
    end
  end

  it 'fails to deadlock from prepending siblings' do
    @target = Label.find_or_create_by_path %w(root parent)
    run_workers(SiblingPrependerWorker)
    children = Label.roots
    uniq_order_values = children.collect { |ea| ea.order_value }.uniq
    expect(children.size).to eq(uniq_order_values.size)

    # The only non-root node should be "root":
    expect(Label.all.select { |ea| ea.root? }).to eq([@target.parent])
  end unless sqlite? # sqlite throws errors from concurrent access

end if run_parallel_tests?
