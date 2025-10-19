# frozen_string_literal: true

# frozen_string_literal: true

require "ostruct"

module SolidFlow
  class Runner
    def initialize(store: SolidFlow.store, time_provider: SolidFlow.configuration.time_provider)
      @store = store
      @time_provider = time_provider
    end

    def run(execution_id)
      store.with_execution(execution_id) do |execution_record|
        workflow_class = SolidFlow.configuration.workflow_registry.fetch(execution_record[:workflow])
        events = store.load_history(execution_id)

        state = Replay.new(workflow_class:, events:, execution_record:).call

        Determinism.assert_graph!(workflow_class, state.execution_state.graph_signature)

        return state if state.finished?

        step_index = state.execution_state.cursor_index
        step_definition = workflow_class.steps[step_index]

        unless step_definition
          complete_execution(execution_id, workflow_class, state, state.ctx)
          return state
        end

        workflow = workflow_class.new(
          ctx: state.ctx.deep_dup,
          execution: build_execution_struct(state.execution_state),
          history: state.history
        )

        consume_pending_signals(execution_id, workflow, state)

        if step_definition.task?
          handle_task_step(execution_id, workflow, step_definition, state)
        else
          handle_inline_step(execution_id, workflow, step_definition, state)
        end
      end
    end

    private

    attr_reader :store, :time_provider

    def build_execution_struct(execution_state)
      OpenStruct.new(
        id: execution_state.id,
        workflow: execution_state.workflow,
        state: execution_state.state,
        cursor_step: execution_state.cursor_step,
        cursor_index: execution_state.cursor_index,
        graph_signature: execution_state.graph_signature,
        metadata: execution_state.metadata
      )
    end

    def consume_pending_signals(execution_id, workflow, state)
      state.signal_buffer.to_a.each do |message|
        next if message.consumed?
        next unless workflow.signal_defined?(message.name)

        SolidFlow.instrument(
          "solidflow.signal.consumed",
          execution_id:,
          workflow: workflow.class.workflow_name,
          signal: message.name,
          payload: message.payload
        )

        workflow.apply_signal(message.name, message.payload)
        persist_context(execution_id, workflow.ctx)
        store.persist_signal_consumed(execution_id:, signal_name: message.name)
      end
    end

    def handle_inline_step(execution_id, workflow, step_definition, state)
      SolidFlow.instrument(
        "solidflow.step.started",
        execution_id:,
        workflow: workflow.class.workflow_name,
        step: step_definition.name
      )

      workflow.reset_wait_context!
      result = nil

      begin
        result =
          if step_definition.block?
            workflow.instance_exec(&step_definition.block)
          else
            nil
          end
      rescue Errors::Cancelled => cancellation
        handle_cancellation(execution_id, workflow, step_definition, state, cancellation)
        return
      rescue StandardError => e
        fail_execution(
          execution_id,
          workflow,
          step_definition,
          state,
          {
            message: e.message,
            class: e.class.name,
            backtrace: e.backtrace
          }
        )
        return
      end

      wait_instructions = workflow.consume_wait_instructions

      if wait_instructions.any?
        handle_waiting_step(execution_id, workflow, step_definition, wait_instructions)
        return
      end

      ctx_snapshot = workflow.ctx.deep_dup
      persist_context(execution_id, ctx_snapshot)

      store.append_event(
        execution_id:,
        type: :step_completed,
        payload: {
          step: step_definition.name,
          result: result,
          ctx_snapshot: ctx_snapshot
        }
      )

      advance_cursor(execution_id, state.execution_state, workflow.class, step_definition)

      SolidFlow.instrument(
        "solidflow.step.completed",
        execution_id:,
        workflow: workflow.class.workflow_name,
        step: step_definition.name,
        result:
      )
    end

    def handle_waiting_step(execution_id, workflow, step_definition, wait_instructions)
      instruction_payloads = wait_instructions.map { |instr| instr.to_h }

      store.append_event(
        execution_id:,
        type: :step_waiting,
        payload: {
          step: step_definition.name,
          instructions: instruction_payloads
        }
      )

      wait_instructions.each do |instruction|
        case instruction.type.to_sym
        when :timer
          schedule_timer(execution_id, workflow, step_definition, instruction)
        when :signal
          # No-op; signals are appended when received.
        end
      end

      SolidFlow.instrument(
        "solidflow.step.waiting",
        execution_id:,
        workflow: workflow.class.workflow_name,
        step: step_definition.name,
        instructions: instruction_payloads
      )
    end

    def schedule_timer(execution_id, workflow, step_definition, instruction)
      run_at =
        if instruction.options[:delay_seconds]
          time_provider.call + instruction.options[:delay_seconds]
        elsif instruction.options[:run_at]
          instruction.options[:run_at]
        else
          raise Errors::WaitInstructionError, "Timer instruction missing scheduling data"
        end

      store.schedule_timer(
        execution_id:,
        step: step_definition.name,
        run_at: run_at,
        instruction: instruction.to_h,
        metadata: instruction.options[:metadata]
      )
    end

    def handle_task_step(execution_id, workflow, step_definition, state)
      task_state = state.task_states[step_definition.name]
      next_attempt = task_state ? task_state.attempt + 1 : 1

      retry_policy = default_retry_policy.merge(step_definition.retry_policy || {})
      max_attempts = retry_policy[:max_attempts] || 1

      if task_state&.finished? && task_state.status == :failed && next_attempt > max_attempts
        fail_execution(execution_id, workflow, step_definition, state, task_state.last_error)
        return
      end

      return if task_state && !task_state.failed?

      idempotency_key = Idempotency.evaluate(
        step_definition.idempotency_key,
        workflow: workflow,
        step: step_definition
      )

      arguments = resolve_task_arguments(step_definition, workflow)

      schedule_at = compute_backoff_timestamp(retry_policy, next_attempt)

      store.append_event(
        execution_id:,
        type: :task_scheduled,
        payload: {
          step: step_definition.name,
          attempt: next_attempt,
          arguments: arguments,
          idempotency_key: idempotency_key
        }
      )

      if next_attempt > 1
        SolidFlow.instrument(
          "solidflow.task.retried",
          execution_id:,
          workflow: workflow.class.workflow_name,
          step: step_definition.name,
          task: step_definition.task,
          attempt: next_attempt
        )
      end

      store.schedule_task(
        execution_id:,
        step: step_definition.name,
        task: step_definition.task,
        arguments:,
        headers: {
          execution_id: execution_id,
          step_name: step_definition.name,
          attempt: next_attempt,
          idempotency_key: idempotency_key,
          workflow_name: workflow.class.workflow_name,
          metadata: workflow.execution.metadata
        },
        run_at: schedule_at
      )

      SolidFlow.instrument(
        "solidflow.task.scheduled",
        execution_id:,
        workflow: workflow.class.workflow_name,
        step: step_definition.name,
        task: step_definition.task,
        attempt: next_attempt,
        idempotency_key: idempotency_key,
        schedule_at: schedule_at
      )
    end

    def resolve_task_arguments(step_definition, workflow)
      arguments = step_definition.options[:arguments]

      case arguments
      when Proc
        workflow.instance_exec(&arguments)
      when Symbol
        workflow.public_send(arguments)
      when Hash
        arguments.deep_dup
      when nil
        workflow.ctx.deep_dup
      else
        arguments
      end
    end

    def compute_backoff_timestamp(retry_policy, attempt)
      return nil if attempt <= 1

      initial_delay = retry_policy[:initial_delay] || 0
      backoff = retry_policy[:backoff]&.to_sym || :constant

      delay =
        case backoff
        when :constant
          initial_delay
        when :exponential
          initial_delay * (2**(attempt - 2))
        else
          initial_delay
        end

      delay = delay.to_f
      delay = 0 if delay.negative?

      time_provider.call + delay
    end

    def default_retry_policy
      {
        max_attempts: 1,
        initial_delay: 0,
        backoff: :constant
      }
    end

    def persist_context(execution_id, ctx)
      store.persist_context(
        execution_id:,
        ctx:
      )
    end

    def advance_cursor(execution_id, execution_state, workflow_class, step_definition)
      next_index = execution_state.cursor_index + 1
      next_step = workflow_class.steps[next_index]&.name

      new_state = if next_index >= workflow_class.steps.size
                    "completed"
                  else
                    "running"
                  end

      store.update_execution(
        execution_id:,
        attributes: {
          cursor_index: next_index,
          cursor_step: next_step,
          state: new_state
        }
      )

      if new_state == "completed"
        store.append_event(
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
        store.enqueue_execution(
          execution_id:,
          reason: :step_advanced
        )
      end
    end

    def complete_execution(execution_id, workflow_class, state, ctx)
      persist_context(execution_id, ctx)
      store.update_execution(
        execution_id:,
        attributes: {
          state: "completed"
        }
      )
      store.append_event(
        execution_id:,
        type: :workflow_completed,
        payload: {}
      )
      SolidFlow.instrument(
        "solidflow.execution.completed",
        execution_id:,
        workflow: workflow_class.workflow_name
      )
    end

    def fail_execution(execution_id, workflow, step_definition, state, error)
      store.update_execution(
        execution_id:,
        attributes: {
          state: "failed",
          last_error: error
        }
      )

      unless state.history.any? { |event| event.type.to_sym == :workflow_failed }
        store.append_event(
          execution_id:,
          type: :workflow_failed,
          payload: {
            step: step_definition.name,
            error: error
          }
        )
      end

      schedule_compensations(execution_id, workflow, state)

      SolidFlow.instrument(
        "solidflow.execution.failed",
        execution_id:,
        workflow: workflow.class.workflow_name,
        step: step_definition.name,
        error: error
      )
    end

    def handle_cancellation(execution_id, workflow, step_definition, state, exception)
      store.update_execution(
        execution_id:,
        attributes: {
          state: "cancelled",
          last_error: { message: exception.message }
        }
      )

      store.append_event(
        execution_id:,
        type: :workflow_cancelled,
        payload: {
          step: step_definition.name,
          reason: exception.message
        }
      )

      SolidFlow.instrument(
        "solidflow.execution.cancelled",
        execution_id:,
        workflow: workflow.class.workflow_name,
        step: step_definition.name,
        reason: exception.message
      )

      schedule_compensations(execution_id, workflow, state)
    end

    def schedule_compensations(execution_id, workflow, state)
      compensation_map = workflow.class.compensations
      return if compensation_map.empty?

      completed_steps = state.step_states.values
                                .select(&:completed?)
                                .map(&:name)

      completed_steps.reverse_each do |step_name|
        task = compensation_map[step_name]
        next unless task

        store.schedule_compensation(
          execution_id:,
          workflow_class: workflow.class,
          step: step_name,
          compensation_task: task,
          context: workflow.ctx.deep_dup
        )
      end
    end
  end
end
