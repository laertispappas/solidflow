# frozen_string_literal: true

module SolidFlow
  module Jobs
    class RunExecutionJob < ActiveJob::Base
      queue_as do
        SolidFlow.configuration.default_execution_queue
      end

      retry_exceptions = [ActiveRecord::Deadlocked]
      retry_exceptions << ActiveRecord::LockWaitTimeout if defined?(ActiveRecord::LockWaitTimeout)
      retry_on(*retry_exceptions, attempts: 5, wait: :exponentially_longer)

      def perform(execution_id)
        SolidFlow::Runner.new.run(execution_id)
      rescue Errors::ExecutionNotFound => e
        SolidFlow.logger.warn("SolidFlow execution not found: #{execution_id} (#{e.class}: #{e.message})")
      end
    end
  end
end
