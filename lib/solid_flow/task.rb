# frozen_string_literal: true

require "active_support/core_ext/hash/keys"
require "active_support/core_ext/string/inflections"

module SolidFlow
  # Base class for all stateless tasks executed out-of-band from the workflow process.
  class Task
    THREAD_KEY = :__solidflow_task_context__

    class << self
      attr_reader :timeout_config, :retry_config, :queue_name, :task_symbol

      def inherited(subclass)
        super
        subclass.instance_variable_set(:@timeout_config, timeout_config&.dup)
        subclass.instance_variable_set(:@retry_config, retry_config&.dup)
        subclass.instance_variable_set(:@queue_name, queue_name)
        subclass.instance_variable_set(:@task_symbol, subclass.default_task_symbol)
        SolidFlow.task_registry.register(subclass.default_task_symbol, subclass)
      end

      def default_task_symbol
        name.demodulize.underscore.to_sym
      end

      def register_as(name)
        @task_symbol = name.to_sym
        SolidFlow.task_registry.register(@task_symbol, self)
      end

      def timeout(value = nil)
        if value
          @timeout_config = value
        else
          @timeout_config
        end
      end

      def retry(options = nil)
        if options
          @retry_config = options.deep_symbolize_keys
        else
          @retry_config || {}
        end
      end

      def queue(name = nil)
        if name
          @queue_name = name
        else
          @queue_name || SolidFlow.configuration.default_task_queue
        end
      end

      def execute(arguments:, headers:)
        context = TaskContext.new(
          execution_id: headers[:execution_id],
          step_name: headers[:step_name],
          attempt: headers[:attempt],
          idempotency_key: headers[:idempotency_key],
          workflow_name: headers[:workflow_name],
          metadata: headers[:metadata] || {}
        )

        SolidFlow.instrument(
          "solidflow.task.started",
          task: task_symbol,
          execution_id: context.execution_id,
          step_name: context.step_name,
          attempt: context.attempt
        )

        result = with_task_context(context) do
          new.perform(**arguments.symbolize_keys)
        end

        SolidFlow.instrument(
          "solidflow.task.completed",
          task: task_symbol,
          execution_id: context.execution_id,
          step_name: context.step_name,
          attempt: context.attempt,
          result:
        )

        result
      rescue StandardError => e
        SolidFlow.instrument(
          "solidflow.task.failed",
          task: task_symbol,
          execution_id: context.execution_id,
          step_name: context.step_name,
          attempt: context.attempt,
          error: e
        )
        raise Errors::TaskFailure.new(e.message, details: { class: e.class.name, backtrace: e.backtrace })
      end

      def current_context
        Thread.current[THREAD_KEY]
      end

      private

      def with_task_context(context)
        previous = Thread.current[THREAD_KEY]
        Thread.current[THREAD_KEY] = context
        yield
      ensure
        Thread.current[THREAD_KEY] = previous
      end
    end

    class TaskContext
      attr_reader :execution_id, :step_name, :attempt, :idempotency_key, :workflow_name, :metadata

      def initialize(execution_id:, step_name:, attempt:, idempotency_key:, workflow_name:, metadata:)
        @execution_id = execution_id
        @step_name = step_name
        @attempt = attempt
        @idempotency_key = idempotency_key
        @workflow_name = workflow_name
        @metadata = metadata
      end
    end

    def perform(**)
      raise NotImplementedError, "Tasks must implement #perform"
    end

    def current_context
      self.class.current_context
    end

    def current_execution_id
      current_context&.execution_id
    end

    def current_step_name
      current_context&.step_name
    end

    def current_attempt
      current_context&.attempt
    end

    def current_idempotency_key
      current_context&.idempotency_key
    end
  end
end
