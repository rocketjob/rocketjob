require_relative "../test_helper"

module Batch
  class WorkerTest < Minitest::Test
    class SimpleJob < RocketJob::Job
      include RocketJob::Batch

      self.destroy_on_complete = false

      input_category slice_size: 10
      output_category

      def perform(record)
        record
      end
    end

    class ExceptionJob < RocketJob::Job
      include RocketJob::Batch

      self.description         = "Exception Tester"
      self.destroy_on_complete = false

      input_category slice_size: 10
      output_category

      def perform(count)
        nil.no_method_error_please if count == 42
      end
    end

    class CategoryJob < RocketJob::Job
      include RocketJob::Batch

      self.description         = "Category Tester"
      self.destroy_on_complete = false

      input_category slice_size: 10
      output_category

      # Register additional output categories for the job
      output_category(name: :main)
      output_category(name: :odd)
      output_category(name: :even)

      # Send Even counts to the main collection with odd results to the :odd
      # category
      def perform(count)
        if count.even?
          # This result will go to the default output collection / category
          count
        else
          # Specify the :odd output category as registered above
          RocketJob::Batch::Result.new(:odd, count)
        end
      end
    end

    class BadCategoryJob < RocketJob::Job
      include RocketJob::Batch

      self.destroy_on_complete = false

      # Register additional output categories for the job
      output_category(name: :main)
      output_category(name: :odd)
      output_category(name: :even)

      # Return an undefined category
      def perform(count)
        # :bad is not registered so will raise an exception
        RocketJob::Batch::Result.new(:bad, count)
      end
    end

    class CompoundCategoryJob < RocketJob::Job
      include RocketJob::Batch

      self.destroy_on_complete = false

      input_category slice_size: 10

      # Register additional output categories for the job
      output_category(name: :main)
      output_category(name: :odd)
      output_category(name: :even)

      # Returns multiple results, each
      def perform(_)
        result = RocketJob::Batch::Results.new
        # A result for the main collections
        result << RocketJob::Batch::Result.new(:main, "main")
        # Custom output collections
        result << RocketJob::Batch::Result.new(:odd, "odd")
        result << RocketJob::Batch::Result.new(:even, "even")
      end
    end

    class RecordNumberJob < RocketJob::Job
      include RocketJob::Batch

      self.destroy_on_complete = false

      input_category slice_size: 1
      output_category

      def perform(_record)
        rocket_job_record_number
      end
    end

    class BoomBatchJob < RocketJob::Job
      include RocketJob::Batch

      def perform(record)
        record
      end

      private

      def boom
        RocketJob.blah
      end
    end

    class BadBeforeBatchJob < BoomBatchJob
      before_batch :boom
    end

    class BadAfterBatchJob < BoomBatchJob
      after_batch :boom
    end

    class NoOutputRetryJob < RocketJob::Job
      include RocketJob::Batch

      self.destroy_on_complete = false

      input_category slice_size: 5

      field :exception_record, type: Integer

      # Do not try this at home. For quick testing only.
      class << self
        attr_reader :processed_records
      end

      # Do not try this at home. For quick testing only.
      def self.clear_processed_records
        @processed_records = []
      end

      @processed_records = []

      def perform(record)
        raise(ArgumentError, "This is the bad record") if record == exception_record

        self.class.processed_records << record

        logger.info("Processing record: #{record}")

        record
      end
    end

    class WithOutputRetryJob < NoOutputRetryJob
      output_category
    end

    class MultipleOutputRetryJob < NoOutputRetryJob
      output_category(name: :main)
      output_category(name: :odd)
      output_category(name: :even)

      # Returns multiple results, each
      def perform(record)
        raise(ArgumentError, "This is the bad record") if record == exception_record

        self.class.processed_records << record

        logger.info("Processing record: #{record}")

        results = RocketJob::Batch::Results.new
        results << RocketJob::Batch::Result.new(:main, record)

        category_name = record.even? ? :even : :odd
        results << RocketJob::Batch::Result.new(category_name, record)
        results
      end
    end

    describe RocketJob::Batch::Worker do
      before do
        RocketJob::Job.destroy_all
      end

      after do
        RocketJob::Job.destroy_all
      end

      describe "#work" do
        it "calls perform method" do
          job          = SimpleJob.new
          record_count = 24
          upload_and_perform(job)
          assert job.completed?, -> { job.as_document.ai }
          assert_equal [:main], job.output_categories.collect(&:name)

          io = StringIO.new
          job.download(io)
          expected = (1..record_count).collect { |i| i }.join("\n") + "\n"
          assert_equal expected, io.string
        end

        it "process multi-record request" do
          lines = 5.times.collect { |i| "line#{i + 1}" }
          job   = SimpleJob.new
          job.upload_slice(lines)
          assert_equal lines.size, job.record_count

          job.perform_now

          assert_equal 0, job.input.failed.count, job.input.to_a.inspect
          assert_equal 0, job.input.queued.count, job.input.to_a.inspect
          assert job.completed?

          job.output.each do |slice|
            assert_equal lines, slice.to_a
          end
        end

        it "process multi-record file with record_counts" do
          file_name = "test/sliced/files/text.txt"
          lines     = []
          File.open(file_name, "rb") do |file|
            file.each_line { |line| lines << line.strip }
          end
          job = RecordNumberJob.new
          job.upload(file_name)
          assert_equal lines.size, job.record_count
          job.perform_now

          assert_equal 0, job.input.failed.count, job.input.to_a.inspect
          assert_equal 0, job.input.queued.count, job.input.to_a.inspect
          assert job.completed?

          slice_record_count = 1
          job.output.each do |slice|
            assert_equal slice_record_count, slice.first, slice
            slice_record_count += job.input_category.slice_size
          end
        end

        it "fails job on exception" do
          # Allow slices to fail so that the job as a whole is marked
          # as failed when no more queued slices are available
          record_count                  = 74
          job                           = ExceptionJob.new
          job.input_category.slice_size = 10
          job.upload do |records|
            (1..record_count).each { |i| records << i }
          end
          worker = RocketJob::Worker.new
          job.start
          # Do not raise exceptions, process all slices
          job.rocket_job_work(worker, false)

          assert_equal [:main], job.output_categories.collect(&:name)
          assert job.failed?

          assert_equal 1, job.input.failed.count, job.input.to_a.inspect
          assert_equal record_count, job.record_count
          assert_equal 0, job.input.queued.count, job.input.to_a.inspect
          assert_equal true, job.failed?, job.state

          assert failed_slice = job.input.first
          assert_equal 1, failed_slice.failure_count
          assert_equal :failed, failed_slice.state
          assert failed_slice.started_at
          assert_nil failed_slice.worker_name

          # Validate exception model on slice
          exception = failed_slice.exception
          assert exception, -> { failed_slice.attributes.ai }
          assert_equal "NoMethodError", exception.class_name
          assert exception.message.include?("no_method_error_please")
          assert_equal 2, failed_slice.processing_record_number
          assert exception.worker_name
          assert exception.backtrace

          # Requeue failed slices
          job.retry!
          assert job.running?, job.state
          assert_equal 0, job.input.failed.count, job.input.to_a.inspect
          assert_equal record_count, job.record_count
          assert_equal 1, job.input.queued.count, job.input.to_a.inspect
          assert_equal true, job.running?, job.state

          assert slice = job.input.first
          assert_equal 1, slice.failure_count
          assert slice.queued?
          assert_nil slice.started_at
          assert_nil slice.worker_name
        end

        it "fails persisted job on exception" do
          # Allow slices to fail so that the job as a whole is marked
          # as failed when no more queued slices are available
          record_count                  = 74
          job                           = ExceptionJob.new
          job.input_category.slice_size = 10
          job.upload do |records|
            (1..record_count).each { |i| records << i }
          end
          worker = RocketJob::Worker.new
          job.start!
          # Do not raise exceptions, process all slices
          job.rocket_job_work(worker, false)

          assert_equal [:main], job.output_categories.collect(&:name)
          assert job.failed?, -> { job.ai }

          job.stub(:may_fail?, true) do
            # Ensure second call sees the first as failed
            assert job.send(:rocket_job_batch_complete?, "blah_worker")
          end

          assert_equal 1, job.input.failed.count, job.input.to_a.inspect
          assert_equal record_count, job.record_count
          assert_equal 0, job.input.queued.count, job.input.to_a.inspect
          assert_equal true, job.failed?, job.state

          assert failed_slice = job.input.first
          assert_equal 1, failed_slice.failure_count
          assert_equal :failed, failed_slice.state
          assert failed_slice.started_at
          assert_nil failed_slice.worker_name

          # Validate exception model on slice
          exception = failed_slice.exception
          assert exception, -> { failed_slice.attributes.ai }
          assert_equal "NoMethodError", exception.class_name
          assert exception.message.include?("no_method_error_please")
          assert_equal 2, failed_slice.processing_record_number
          assert exception.worker_name
          assert exception.backtrace

          # Requeue failed slices
          job.retry!
          assert job.running?, job.state
          assert_equal 0, job.input.failed.count, job.input.to_a.inspect
          assert_equal record_count, job.record_count
          assert_equal 1, job.input.queued.count, job.input.to_a.inspect
          assert_equal true, job.running?, job.state

          assert slice = job.input.first
          assert_equal 1, slice.failure_count
          assert slice.queued?
          assert_nil slice.started_at
          assert_nil slice.worker_name
        end

        it "fails the job when before_batch raises an exception" do
          job = BadBeforeBatchJob.new
          upload_and_perform(job)
          assert job.failed?, -> { job.as_document.ai }
        end

        it "fails the job when after_batch raises an exception" do
          job = BadAfterBatchJob.new
          upload_and_perform(job)
          assert job.failed?, -> { job.as_document.ai }
        end

        describe "retry handling with no output categories" do
          it "processes all records without retry" do
            NoOutputRetryJob.clear_processed_records
            job          = NoOutputRetryJob.new
            record_count = 24
            upload_and_perform(job, record_count: record_count)
            assert job.completed?, -> { job.as_document.ai }

            expected = (1..record_count).to_a
            assert_equal expected, NoOutputRetryJob.processed_records
          end

          it "skips processed records in failed first slice" do
            NoOutputRetryJob.clear_processed_records
            job          = NoOutputRetryJob.new(exception_record: 3)
            record_count = 24
            upload_and_perform(job, record_count: record_count)
            assert job.failed?, -> { job.as_document.ai }
            assert_equal "ArgumentError", job.input.first.exception.class_name

            expected = (1..2).to_a + (6..record_count).to_a
            assert_equal expected, NoOutputRetryJob.processed_records
            NoOutputRetryJob.clear_processed_records

            # Allow job to continue processing
            job.exception_record = nil
            job.retry
            job.perform_now

            assert job.completed?, -> { job.as_document.ai }

            # Only the remaining records on the failed slice need to be processed on retry
            expected = (3..5).to_a
            assert_equal expected, NoOutputRetryJob.processed_records
          end

          it "skips processed records in failed last slice" do
            NoOutputRetryJob.clear_processed_records
            job          = NoOutputRetryJob.new(exception_record: 24)
            record_count = 24
            upload_and_perform(job, record_count: record_count)
            assert job.failed?, -> { job.as_document.ai }
            assert_equal "ArgumentError", job.input.first.exception.class_name

            expected = (1..23).to_a
            assert_equal expected, NoOutputRetryJob.processed_records
            NoOutputRetryJob.clear_processed_records

            # Allow job to continue processing
            job.exception_record = nil
            job.retry
            job.perform_now

            assert job.completed?, -> { job.as_document.ai }

            # Only the remaining records on the failed slice need to be processed on retry
            expected = [24]
            assert_equal expected, NoOutputRetryJob.processed_records
          end
        end

        describe "retry handling with output categories" do
          it "processes all records without retry" do
            WithOutputRetryJob.clear_processed_records
            job          = WithOutputRetryJob.new
            record_count = 24
            upload_and_perform(job, record_count: record_count)
            assert job.completed?, -> { job.as_document.ai }

            expected = (1..record_count).to_a
            assert_equal expected, WithOutputRetryJob.processed_records

            io = StringIO.new
            job.download(io)
            expected = (1..record_count).collect { |i| i }.join("\n") + "\n"
            assert_equal expected, io.string
          end

          it "skips processed records in failed first slice" do
            WithOutputRetryJob.clear_processed_records
            job          = WithOutputRetryJob.new(exception_record: 3)
            record_count = 24
            upload_and_perform(job, record_count: record_count)
            assert job.failed?, -> { job.as_document.ai }
            assert_equal "ArgumentError", job.input.first.exception.class_name

            expected = (1..2).to_a + (6..record_count).to_a
            assert_equal expected, WithOutputRetryJob.processed_records
            WithOutputRetryJob.clear_processed_records

            # Allow job to continue processing
            job.exception_record = nil
            job.retry
            job.perform_now

            assert job.completed?, -> { job.as_document.ai }

            # Only the remaining records on the failed slice need to be processed on retry
            expected = (3..5).to_a
            assert_equal expected, WithOutputRetryJob.processed_records

            io = StringIO.new
            job.download(io)
            expected = (1..record_count).collect { |i| i }.join("\n") + "\n"
            assert_equal expected, io.string
          end

          it "skips processed records in failed last slice" do
            WithOutputRetryJob.clear_processed_records
            job          = WithOutputRetryJob.new(exception_record: 24)
            record_count = 24
            upload_and_perform(job, record_count: record_count)
            assert job.failed?, -> { job.as_document.ai }
            assert_equal "ArgumentError", job.input.first.exception.class_name

            expected = (1..23).to_a
            assert_equal expected, WithOutputRetryJob.processed_records
            WithOutputRetryJob.clear_processed_records

            # Allow job to continue processing
            job.exception_record = nil
            job.retry
            job.perform_now

            assert job.completed?, -> { job.as_document.ai }

            # Only the remaining records on the failed slice need to be processed on retry
            expected = [24]
            assert_equal expected, WithOutputRetryJob.processed_records

            io = StringIO.new
            job.download(io)
            expected = (1..record_count).collect { |i| i }.join("\n") + "\n"
            assert_equal expected, io.string
          end

          it "skips processed records in failed last slice of multiple categories" do
            MultipleOutputRetryJob.clear_processed_records
            job          = MultipleOutputRetryJob.new(exception_record: 24)
            record_count = 24
            upload_and_perform(job, record_count: record_count)
            assert job.failed?, -> { job.as_document.ai }
            assert_equal "ArgumentError", job.input.first.exception.class_name

            expected = (1..23).to_a
            assert_equal expected, MultipleOutputRetryJob.processed_records
            MultipleOutputRetryJob.clear_processed_records

            # Allow job to continue processing
            job.exception_record = nil
            job.retry
            job.perform_now

            assert job.completed?, -> { job.as_document.ai }

            # Only the remaining records on the failed slice need to be processed on retry
            expected = [24]
            assert_equal expected, MultipleOutputRetryJob.processed_records

            io = StringIO.new
            job.download(io)
            expected = (1..record_count).collect { |i| i }.join("\n") + "\n"
            assert_equal expected, io.string

            io = StringIO.new
            job.download(io, category: :even)
            expected = (1..record_count).collect { |i| i if i.even? }.compact.join("\n") + "\n"
            assert_equal expected, io.string

            io = StringIO.new
            job.download(io, category: :odd)
            expected = (1..record_count).collect { |i| i unless i.even? }.compact.join("\n") + "\n"
            assert_equal expected, io.string
          end
        end
      end

      describe "#output_categories" do
        it "collects results" do
          record_count = 1024
          job          = CategoryJob.new
          job.upload do |records|
            (1..record_count).each { |i| records << i }
          end
          job.perform_now
          assert job.completed?, job.attributes.ai
          assert_equal %i[main odd even], job.output_categories.collect(&:name)

          io = StringIO.new
          job.download(io)
          expected_evens = (1..(record_count / 2)).collect { |i| i * 2 }.join("\n") + "\n"
          assert_equal expected_evens, io.string

          io = StringIO.new
          job.download(io, category: :odd)
          expected_odds = (0..(record_count / 2 - 1)).collect { |i| i * 2 + 1 }.join("\n") + "\n"
          assert_equal expected_odds, io.string
        end

        it "fails on an unregistered category" do
          record_count = 24
          job          = BadCategoryJob.new
          job.upload do |records|
            (1..record_count).each { |i| records << i }
          end
          assert_raises "ArgumentError" do
            job.perform_now
          end
          # Since it ran inline above, the exception is re-raised preventing the job from completing
          # Complete remainder of job
          job.perform_now

          assert job.failed?, job.status.ai
          assert_equal 1, job.input.failed.count, job.input.to_a.inspect

          assert failed_slice = job.input.first
          assert failed_slice.failed?, failed_slice
          assert_equal 1, failed_slice.failure_count
          assert failed_slice.started_at
          assert_nil failed_slice.worker_name

          # Validate exception model on slice
          assert exception = failed_slice.exception
          assert_equal "ArgumentError", exception.class_name, exception
          assert "Invalid RocketJob Output Category: bad", exception.message
          assert exception.worker_name
          assert exception.backtrace
        end
      end

      describe "#rocket_job_active_workers" do
        let(:worker) { RocketJob::Worker.new(server_name: "worker1:123", id: 1) }
        let(:worker2) { RocketJob::Worker.new(server_name: "worker1:5673", id: 1) }
        let(:worker3) { RocketJob::Worker.new(server_name: "worker1:5673", id: 2) }

        let(:loaded_job) do
          job                           = SimpleJob.new(worker_name: worker.name, state: :running, sub_state: :processing, started_at: 1.minute.ago)
          job.input_category.slice_size = 2
          job.upload do |stream|
            10.times { |i| stream << "line#{i + 1}" }
          end
          job.save!
          assert_equal 5, job.input.count
          job
        end

        it "should return empty hash for no active jobs" do
          assert_equal([], SimpleJob.create!.rocket_job_active_workers)
        end

        it "should return active workers in :before state" do
          assert job = SimpleJob.new(worker_name: worker.name, state: :running, sub_state: :before, started_at: 1.minute.ago)
          assert_equal :before, job.sub_state

          assert active = job.rocket_job_active_workers
          assert_equal 1, active.size
          assert active_worker = active.first
          assert_equal job.id, active_worker.job.id
          assert_equal worker.name, active_worker.name
          assert_equal job.started_at, active_worker.started_at
          assert active_worker.duration_s
          assert active_worker.duration
        end

        it "should return active workers while :processing" do
          assert slice1 = loaded_job.input.next_slice(worker.name)
          assert slice2 = loaded_job.input.next_slice(worker2.name)
          assert slice3 = loaded_job.input.next_slice(worker3.name)

          assert active = loaded_job.rocket_job_active_workers
          assert_equal 3, active.size, -> { active.ai }

          assert active_worker = active.first
          assert_equal loaded_job.id, active_worker.job.id
          assert_equal worker.name, active_worker.name
          assert_equal slice1.started_at, active_worker.started_at
          assert active_worker.duration_s
          assert active_worker.duration

          assert active_worker = active.second
          assert_equal loaded_job.id, active_worker.job.id
          assert_equal worker2.name, active_worker.name
          assert_equal slice2.started_at, active_worker.started_at
          assert active_worker.duration_s
          assert active_worker.duration

          assert active_worker = active.last
          assert_equal loaded_job.id, active_worker.job.id
          assert_equal worker3.name, active_worker.name
          assert_equal slice3.started_at, active_worker.started_at
          assert active_worker.duration_s
          assert active_worker.duration
        end
      end

      def upload_and_perform(job, record_count: 24)
        job.upload do |records|
          (1..record_count).each { |i| records << i }
        end
        worker = RocketJob::Worker.new
        job.start
        job.rocket_job_work(worker, false)
        job.perform_now
      end
    end
  end
end
