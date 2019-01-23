require 'rocket_job/supervisor/subscriber/logger'
require 'rocket_job/supervisor/subscriber/server'
require 'rocket_job/supervisor/subscriber/worker'
require 'rocket_job/supervisor/shutdown'

module RocketJob
  # Starts a server instance, along with the workers and ensures workers remain running until they need to shutdown.
  class Supervisor
    include SemanticLogger::Loggable
    include Supervisor::Shutdown

    attr_reader :server, :worker_pool
    attr_accessor :worker_id

    # Start the Supervisor, using the supplied attributes to create a new Server instance.
    def self.run(attrs = {})
      Thread.current.name = 'rocketjob main'
      RocketJob.create_indexes
      register_signal_handlers

      server = Server.create!(attrs)
      new(server).run
    ensure
      server&.destroy
    end

    def initialize(server)
      @server      = server
      @worker_pool = WorkerPool.new(server.name, server.filter)
      @mutex       = Mutex.new
    end

    def run
      logger.info "Using MongoDB Database: #{RocketJob::Job.collection.database.name}"
      logger.info('Running with filter', server.filter) if server.filter
      server.started!
      logger.info 'Rocket Job Server started'

      event_listener = Thread.new { Event.event_listener }
      Event.subscribe(Supervisor::Subscriber::Server.new(self)) do
        Event.subscribe(Supervisor::Subscriber::Worker.new(self)) do
          Event.subscribe(Supervisor::Subscriber::Logger.new) do
            supervise_pool
            stop!
          end
        end
      end
    rescue ::Mongoid::Errors::DocumentNotFound
      logger.info('Server has been destroyed. Going down hard!')
    rescue Exception => exc
      logger.error('RocketJob::Server is stopping due to an exception', exc)
    ensure
      event_listener.kill if event_listener
      # Logs the backtrace for each running worker
      worker_pool.log_backtraces
      logger.info('Shutdown Complete')
    end

    def stop!
      server.stop! if server.may_stop?
      worker_pool.stop!
      while !worker_pool.join
        logger.info 'Waiting for workers to finish processing ...'
        # One or more workers still running so update heartbeat so that server reports "alive".
        server.refresh(worker_pool.living_count)
      end
    end

    def supervise_pool
      stagger = true
      while !self.class.shutdown?
        synchronize do
          if server.running?
            worker_pool.prune
            worker_pool.rebalance(server.max_workers, stagger)
            stagger = false
          elsif server.paused?
            worker_pool.stop!
            sleep(0.1)
            worker_pool.prune
            stagger = true
          else
            break
          end
        end

        self.class.wait_for_event(Config.instance.heartbeat_seconds)

        break if self.class.shutdown?

        synchronize { server.refresh(worker_pool.living_count) }
      end
    end

    def synchronize(&block)
      @mutex.synchronize(&block)
    end
  end
end
