require 'rocketjob'
module Jobs
  class TestJob < RocketJob::Job
    rocket_job do |job|
      job.priority = 51
    end

    @@result = nil

    # For holding test results
    def self.result
      @@result
    end

    def perform(first)
      @@result = first + 1
    end

    def sum(a, b)
      @@result = a + b
    end

    # Test silencing noisy logging
    def noisy_logger
      logger.info 'some very noisy logging'
    end

    # Test increasing log level for debugging purposes
    def debug_logging
      logger.trace 'enable tracing level for just the job instance'
    end

    #
    # New style callbacks
    #
    before(:event) do |hash|
      hash['before_event'] += 1
      # Change jobs priority
      self.priority = 27
    end

    # Second before event that must be run first since it is defined last
    # If run in the wrong order will result in 'nil does not understand +='
    before(:event) do |hash|
      hash['before_event'] = 1
    end

    # TODO: around callbacks are not working yet because the last block is being
    # run in the scope of the class and not the job instance

    # around(:event) do |hash, &block|
    #   ap hash
    #   ap block
    #   # After all the before callbacks
    #   hash['before_event'] += 1
    #   #block.call(hash)
    #   #instance_exec(hash, &block)
    #   # Before any after callbacks
    #   hash['after_event'] = nil
    # end

    def event(hash)
      3645
    end

    after(:event) do |hash|
      hash['after_event'] = 1
    end

    # Second after event that must be run second since it is after the one above
    # If run in the wrong order will result in 'nil does not understand +='
    after(:event) do |hash|
      hash['after_event'] += 1
    end

    #
    # Deprecated callbacks
    #
    def before_old_event(hash)
      hash['before_event'] = true
    end

    def old_event(hash)
      4589
    end

    def after_old_event(hash)
      hash['after_event'] = true
    end

  end
end
