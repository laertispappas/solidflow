# frozen_string_literal: true

module SolidFlow
  module Stores
    class Base
      def initialize(event_serializer:, time_provider:, logger:)
        @event_serializer = event_serializer
        @time_provider = time_provider
        @logger = logger
      end

      attr_reader :event_serializer, :time_provider, :logger

      def start_execution(workflow_class:, input:, graph_signature:)
        raise NotImplementedError
      end

      def signal_execution(execution_id:, workflow_class:, signal_name:, payload:)
        raise NotImplementedError
      end

      def query_execution(execution_id:, workflow_class:)
        raise NotImplementedError
      end

      def with_execution(execution_id, lock: true)
        raise NotImplementedError
      end

      def load_history(execution_id)
        raise NotImplementedError
      end

      def append_event(execution_id:, type:, payload:)
        raise NotImplementedError
      end

      def update_execution(execution_id:, attributes:)
        raise NotImplementedError
      end

      def persist_context(execution_id:, ctx:)
        raise NotImplementedError
      end

      def enqueue_execution(execution_id:, reason:)
        raise NotImplementedError
      end

      def schedule_task(execution_id:, step:, task:, arguments:, headers:, run_at: nil)
        raise NotImplementedError
      end

      def record_task_result(execution_id:, step:, result:, attempt:, ctx_snapshot:, idempotency_key:)
        raise NotImplementedError
      end

      def record_task_failure(execution_id:, step:, attempt:, error:, retryable:)
        raise NotImplementedError
      end

      def schedule_timer(execution_id:, step:, run_at:, instruction:, metadata:)
        raise NotImplementedError
      end

      def mark_timer_fired(timer_id:)
        raise NotImplementedError
      end

      def persist_signal_consumed(execution_id:, signal_name:)
        raise NotImplementedError
      end

      def schedule_compensation(execution_id:, workflow_class:, step:, compensation_task:, context:)
        raise NotImplementedError
      end

      def record_compensation_result(execution_id:, step:, compensation_task:, result:)
        raise NotImplementedError
      end

      def record_compensation_failure(execution_id:, step:, compensation_task:, error:)
        raise NotImplementedError
      end
    end
  end
end
