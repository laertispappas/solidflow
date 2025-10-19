# frozen_string_literal: true

module SolidFlow
  module Jobs
    class RunTaskJob < ActiveJob::Base
      queue_as do
        SolidFlow.configuration.default_task_queue
      end

      def perform(execution_id, step_name, task_name, arguments, headers)
        headers = headers.deep_symbolize_keys
        arguments = arguments.deep_symbolize_keys if arguments.respond_to?(:deep_symbolize_keys)

        task_class = SolidFlow.task_registry.fetch(task_name)
        workflow_class = SolidFlow.configuration.workflow_registry.fetch(headers.fetch(:workflow_name))
        attempt = headers[:attempt] || 1
        idempotency_key = headers[:idempotency_key]
        compensation = headers[:compensation]

        result = task_class.execute(arguments: arguments || {}, headers:)

        SolidFlow.store.with_execution(execution_id) do |_|
          if compensation
            SolidFlow.store.record_compensation_result(
              execution_id:,
              step: step_name.to_sym,
              compensation_task: headers[:compensation_task],
              result:
            )
          else
            SolidFlow.store.record_task_result(
              execution_id:,
              workflow_class:,
              step: step_name.to_sym,
              result:,
              attempt:,
              idempotency_key: idempotency_key
            )
          end
        end

        SolidFlow.instrument(
          "solidflow.task.completed",
          execution_id:,
          workflow: workflow_class.workflow_name,
          step: step_name,
          task: task_name,
          attempt:,
          result:,
          compensation: compensation
        )
      rescue Errors::TaskFailure => failure
        retryable = retryable?(workflow_class, step_name, attempt, headers)

        SolidFlow.store.with_execution(execution_id) do |_|
          if headers[:compensation]
            SolidFlow.store.record_compensation_failure(
              execution_id:,
              step: step_name.to_sym,
              compensation_task: headers[:compensation_task],
              error: {
                message: failure.message,
                class: failure.details&.fetch(:class, failure.class.name),
                backtrace: Array(failure.details&.fetch(:backtrace, failure.backtrace))
              }
            )
          else
            SolidFlow.store.record_task_failure(
              execution_id:,
              workflow_class:,
              step: step_name.to_sym,
              attempt:,
              error: {
                message: failure.message,
                class: failure.details&.fetch(:class, failure.class.name),
                backtrace: Array(failure.details&.fetch(:backtrace, failure.backtrace))
              },
              retryable:
            )
          end
        end

        SolidFlow.instrument(
          "solidflow.task.failed",
          execution_id:,
          workflow: workflow_class.workflow_name,
          step: step_name,
          task: task_name,
          attempt:,
          error: failure,
          compensation: headers[:compensation]
        )
      end

      private

      def retryable?(workflow_class, step_name, attempt, headers)
        return false if headers[:compensation]

        step_definition = workflow_class.steps.find { |step| step.name.to_sym == step_name.to_sym }
        policy = step_definition&.retry_policy || {}
        max_attempts = policy[:max_attempts] || 1
        attempt < max_attempts
      end
    end
  end
end
