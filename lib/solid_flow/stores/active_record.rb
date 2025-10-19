# frozen_string_literal: true

require "ostruct"

module SolidFlow
  module Stores
    class ActiveRecord < Base
      THREAD_EXECUTION = :__solidflow_current_execution__

      def start_execution(workflow_class:, input:, graph_signature:)
        execution_id = SolidFlow.configuration.id_generator.call
        now = time_provider.call
        first_step = workflow_class.steps.first&.name
        input_payload = input.respond_to?(:deep_stringify_keys) ? input.deep_stringify_keys : input

        execution = SolidFlow::Execution.create!(
          id: execution_id,
          workflow: workflow_class.workflow_name,
          state: "running",
          ctx: input_payload,
          cursor_step: first_step&.to_s,
          cursor_index: 0,
          graph_signature: graph_signature,
          metadata: {},
          started_at: now,
          updated_at: now
        )

        append_event(
          execution_id: execution.id,
          type: :workflow_started,
          payload: { input: input }
        )

        enqueue_execution(
          execution_id: execution.id,
          reason: :start
        )

        build_handle(execution)
      end

      def signal_execution(execution_id:, workflow_class:, signal_name:, payload:)
        execution = SolidFlow::Execution.find(execution_id)

        message = execution.signal_messages.create!(
          signal_name: signal_name.to_s,
          payload: payload,
          metadata: {},
          status: "pending",
          received_at: time_provider.call
        )

        append_event(
          execution_id: execution.id,
          type: :signal_received,
          payload: {
            signal: signal_name,
            payload: payload,
            metadata: message.metadata,
            received_at: message.received_at
          }
        )

        enqueue_execution(
          execution_id: execution.id,
          reason: :signal
        )

        SolidFlow.instrument(
          "solidflow.signal.received",
          execution_id: execution.id,
          workflow: workflow_class.workflow_name,
          signal: signal_name,
          payload:
        )
      end

      def query_execution(execution_id:, workflow_class:)
        execution = SolidFlow::Execution.find(execution_id)
        events = load_history(execution_id)
        state = Replay.new(
          workflow_class:,
          events:,
          execution_record: serialize_execution(execution)
        ).call

        yield(state)
      end

      def with_execution(execution_id, lock: true)
        SolidFlow::Execution.transaction do
          relation = SolidFlow::Execution.where(id: execution_id)
          relation = relation.lock("FOR UPDATE SKIP LOCKED") if lock
          execution = relation.first
          raise Errors::ExecutionNotFound, execution_id unless execution

          previous = Thread.current[THREAD_EXECUTION]
          Thread.current[THREAD_EXECUTION] = execution

          yield serialize_execution(execution)
        ensure
          Thread.current[THREAD_EXECUTION] = previous
        end
      end

      def load_history(execution_id)
        SolidFlow::Event.where(execution_id:)
                        .ordered
                        .map(&:to_replay_event)
      end

      def append_event(execution_id:, type:, payload:, idempotency_key: nil)
        execution = execution_for(execution_id)

        next_sequence = (execution.events.maximum(:sequence) || 0) + 1

        execution.events.create!(
          sequence: next_sequence,
          event_type: type.to_s,
          payload: payload,
          recorded_at: time_provider.call,
          idempotency_key:
        )
      end

      def update_execution(execution_id:, attributes:)
        execution = execution_for(execution_id)
        execution.update!(normalize_attributes(attributes))
      end

      def persist_context(execution_id:, ctx:)
        execution = execution_for(execution_id)
        execution.update!(ctx: ctx.deep_stringify_keys)
      end

      def enqueue_execution(execution_id:, reason:)
        SolidFlow.instrument(
          "solidflow.execution.enqueued",
          execution_id:,
          reason:
        )
        SolidFlow::Jobs::RunExecutionJob.perform_later(execution_id)
      end

      def schedule_task(execution_id:, step:, task:, arguments:, headers:, run_at: nil)
        job = SolidFlow::Jobs::RunTaskJob
        if run_at
          job.set(wait_until: run_at).perform_later(execution_id, step, task, arguments, headers)
        else
          job.perform_later(execution_id, step, task, arguments, headers)
        end
      end

      def record_task_result(execution_id:, workflow_class:, step:, result:, attempt:, idempotency_key:)
        execution = execution_for(execution_id)

        existing = execution.events.where(
          event_type: "task_completed",
          idempotency_key:
        ).first

        return if existing

        ctx = execution.ctx_hash
        ctx[step.to_s] = result

        steps = workflow_class.steps
        next_index = execution.cursor_index + 1
        next_step = steps[next_index]&.name
        new_state = next_step ? "running" : "completed"

        execution.assign_attributes(
          ctx: ctx.deep_stringify_keys,
          cursor_index: next_index,
          cursor_step: next_step&.to_s,
          state: new_state,
          last_error: nil
        )
        execution.save!

        append_event(
          execution_id:,
          type: :task_completed,
          payload: {
            step: step,
            result: result,
            attempt: attempt,
            ctx_snapshot: ctx,
            idempotency_key:
          },
          idempotency_key: idempotency_key
        )

        if new_state == "completed"
          append_event(
            execution_id:,
            type: :workflow_completed,
            payload: {}
          )
          SolidFlow.instrument(
            "solidflow.execution.completed",
            execution_id:,
            workflow: workflow_class.workflow_name
          )
        else
          enqueue_execution(
            execution_id:,
            reason: :task_completed
          )
        end
      end

      def record_task_failure(execution_id:, workflow_class:, step:, attempt:, error:, retryable:)
        execution = execution_for(execution_id)

        execution.update!(
          last_error: error,
          state: retryable ? "running" : "failed"
        )

        append_event(
          execution_id:,
          type: :task_failed,
          payload: {
            step: step,
            attempt: attempt,
            error: error,
            retryable: retryable
          }
        )

        if retryable
          enqueue_execution(
            execution_id:,
            reason: :task_failed
          )
        else
          append_event(
            execution_id:,
            type: :workflow_failed,
            payload: {
              step: step,
              error: error
            }
          )

          SolidFlow.instrument(
            "solidflow.execution.failed",
            execution_id:,
            step: step,
            error: error
          )
        end
      end

      def schedule_timer(execution_id:, step:, run_at:, instruction:, metadata:)
        execution = execution_for(execution_id)

        timer = execution.timers.create!(
          step: step.to_s,
          run_at: run_at,
          status: "scheduled",
          instruction: instruction,
          metadata: metadata
        )

        append_event(
          execution_id:,
          type: :timer_scheduled,
          payload: {
            step: step,
            timer_id: timer.id,
            run_at: run_at,
            metadata: metadata
          }
        )

        SolidFlow.instrument(
          "solidflow.timer.scheduled",
          execution_id: execution.id,
          timer_id: timer.id,
          step: step,
          run_at: run_at
        )
      end

      def mark_timer_fired(timer_id:)
        timer = SolidFlow::Timer.lock.find(timer_id)
        return if timer.fired?

        timer.update!(status: "fired", fired_at: time_provider.call)

        append_event(
          execution_id: timer.execution_id,
          type: :timer_fired,
          payload: {
            timer_id: timer.id,
            step: timer.step
          }
        )

        enqueue_execution(
          execution_id: timer.execution_id,
          reason: :timer_fired
        )
      end

      def persist_signal_consumed(execution_id:, signal_name:)
        message = SolidFlow::SignalMessage
                  .where(execution_id:, signal_name: signal_name.to_s, status: "pending")
                  .order(:received_at)
                  .first

        return unless message

        message.update!(
          status: "consumed",
          consumed_at: time_provider.call
        )

        append_event(
          execution_id:,
          type: :signal_consumed,
          payload: {
            signal: signal_name
          }
        )

        SolidFlow.instrument(
          "solidflow.signal.consumed",
          execution_id:,
          signal: signal_name
        )
      end

      def schedule_compensation(execution_id:, workflow_class:, step:, compensation_task:, context:)
        execution = execution_for(execution_id)

        already_scheduled = execution.events.where(event_type: "compensation_scheduled")
                                            .where("payload ->> 'step' = ?", step.to_s)
                                            .where("payload ->> 'task' = ?", compensation_task.to_s)
                                            .exists?
        return if already_scheduled

        append_event(
          execution_id:,
          type: :compensation_scheduled,
          payload: {
            step: step,
            task: compensation_task
          }
        )

        headers = {
          execution_id: execution_id,
          step_name: step,
          attempt: 1,
          idempotency_key: Idempotency.digest(execution_id, step, "compensation"),
          workflow_name: workflow_class.workflow_name,
          metadata: execution.metadata,
          compensation: true,
          compensation_task: compensation_task
        }

        SolidFlow::Jobs::RunTaskJob.perform_later(
          execution_id,
          step,
          compensation_task,
          context,
          headers
        )

        SolidFlow.instrument(
          "solidflow.compensation.scheduled",
          execution_id:,
          step: step,
          task: compensation_task
        )
      end

      def record_compensation_result(execution_id:, step:, compensation_task:, result:)
        append_event(
          execution_id:,
          type: :compensation_completed,
          payload: {
            step: step,
            task: compensation_task,
            result: result
          }
        )

        SolidFlow.instrument(
          "solidflow.compensation.completed",
          execution_id:,
          step: step,
          task: compensation_task,
          result: result
        )
      end

      def record_compensation_failure(execution_id:, step:, compensation_task:, error:)
        append_event(
          execution_id:,
          type: :compensation_failed,
          payload: {
            step: step,
            task: compensation_task,
            error: error
          }
        )

        SolidFlow.instrument(
          "solidflow.compensation.failed",
          execution_id:,
          step: step,
          task: compensation_task,
          error: error
        )
      end

      private

      def execution_for(execution_id)
        current = Thread.current[THREAD_EXECUTION]
        return current if current&.id == execution_id

        SolidFlow::Execution.find(execution_id)
      end

      def serialize_execution(execution)
        {
          id: execution.id,
          workflow: execution.workflow,
          state: execution.state,
          ctx: execution.ctx_hash,
          cursor_step: execution.cursor_step,
          cursor_index: execution.cursor_index,
          graph_signature: execution.graph_signature,
          metadata: execution.metadata || {}
        }
      end

      def normalize_attributes(attributes)
        attributes.transform_keys(&:to_s).tap do |normalized|
          normalized["cursor_step"] = normalized["cursor_step"].to_s if normalized.key?("cursor_step") && !normalized["cursor_step"].nil?
        end
      end

      def build_handle(execution)
        OpenStruct.new(
          id: execution.id,
          workflow: execution.workflow,
          state: execution.state,
          cursor_step: execution.cursor_step,
          cursor_index: execution.cursor_index
        )
      end
    end
  end
end
