# frozen_string_literal: true

module SolidFlow
  class Replay
    Event = Struct.new(:id, :type, :sequence, :payload, :recorded_at, keyword_init: true)

    StepState = Struct.new(
      :name,
      :status,
      :attempt,
      :last_result,
      :last_error,
      :idempotency_key,
      :wait_instructions,
      keyword_init: true
    ) do
      def waiting?
        status == :waiting
      end

      def completed?
        status == :completed
      end

      def failed?
        status == :failed
      end
    end

    TaskState = Struct.new(
      :step,
      :status,
      :attempt,
      :idempotency_key,
      :last_result,
      :last_error,
      keyword_init: true
    ) do
      def finished?
        %i[completed failed].include?(status)
      end
    end

    TimerState = Struct.new(
      :id,
      :step,
      :run_at,
      :status,
      :metadata,
      keyword_init: true
    ) do
      def pending?
        status == :scheduled
      end
    end

    AwaitingState = Struct.new(
      :step,
      :instructions,
      keyword_init: true
    ) do
      def timer_instructions
        instructions.select { |inst| inst[:type].to_sym == :timer }
      end

      def signal_instructions
        instructions.select { |inst| inst[:type].to_sym == :signal }
      end
    end

    ExecutionState = Struct.new(
      :id,
      :workflow,
      :state,
      :cursor_step,
      :cursor_index,
      :graph_signature,
      :metadata,
      keyword_init: true
    ) do
      def finished?
        %w[completed failed cancelled].include?(state)
      end
    end

    State = Struct.new(
      :execution_state,
      :ctx,
      :history,
      :step_states,
      :awaiting,
      :task_states,
      :timer_states,
      :signal_buffer,
      keyword_init: true
    ) do
      def finished?
        execution_state.finished?
      end

      def current_step
        execution_state.cursor_step
      end

      def current_step_state
        step_states[execution_state.cursor_step&.to_sym]
      end
    end

    attr_reader :workflow_class, :events, :execution_record

    def initialize(workflow_class:, events:, execution_record:)
      @workflow_class = workflow_class
      @events = Array(events)
      @execution_record = execution_record
    end

    def call
      execution_state = ExecutionState.new(
        id: execution_record.fetch(:id),
        workflow: execution_record.fetch(:workflow),
        state: execution_record.fetch(:state),
        cursor_step: execution_record[:cursor_step]&.to_sym,
        cursor_index: execution_record[:cursor_index] || 0,
        graph_signature: execution_record[:graph_signature],
        metadata: execution_record[:metadata] || {}
      )

      ctx = (execution_record[:ctx] || {}).with_indifferent_access

      step_states = {}
      workflow_class.steps.each do |step|
        step_states[step.name] = StepState.new(
          name: step.name,
          status: :idle,
          attempt: 0,
          last_result: nil,
          last_error: nil,
          idempotency_key: nil,
          wait_instructions: []
        )
      end

      task_states = {}
      timer_states = {}
      signal_buffer = Signals::Buffer.new
      awaiting = nil

      events.each do |event|
        type = event.type.to_sym
        raw_payload = event.payload || {}
        payload = raw_payload.is_a?(Hash) ? raw_payload.deep_symbolize_keys : raw_payload

        case type
        when :workflow_started
          ctx.merge!(payload[:input] || {})
        when :step_waiting
          step = payload.fetch(:step).to_sym
          instructions = Array(payload[:instructions]).map do |inst|
            inst.deep_symbolize_keys
          end
          awaiting = AwaitingState.new(step:, instructions:)
          if step_states[step]
            step_states[step].status = :waiting
            step_states[step].wait_instructions = instructions
          end
        when :step_completed
          step = payload.fetch(:step).to_sym
          step_state = step_states[step]
          if step_state
            step_state.status = :completed
            step_state.wait_instructions = []
            step_state.last_result = payload[:result]
            step_state.last_error = nil
            step_state.attempt = payload[:attempt] if payload.key?(:attempt)
            step_state.idempotency_key = payload[:idempotency_key]
          end
          ctx.merge!(payload[:ctx_snapshot] || {})
          awaiting = nil if awaiting&.step == step
        when :task_scheduled
          step = payload.fetch(:step).to_sym
          task_states[step] = TaskState.new(
            step:,
            status: :scheduled,
            attempt: payload[:attempt] || 1,
            idempotency_key: payload[:idempotency_key],
            last_result: nil,
            last_error: nil
          )
          if step_states[step]
            step_states[step].status = :task_scheduled
            step_states[step].attempt = payload[:attempt] || 1
            step_states[step].idempotency_key = payload[:idempotency_key]
          end
        when :task_completed
          step = payload.fetch(:step).to_sym
          task_state = task_states[step] ||= TaskState.new(step:, status: :scheduled, attempt: 0, idempotency_key: nil, last_result: nil, last_error: nil)
          task_state.status = :completed
          task_state.attempt = payload[:attempt] || task_state.attempt
          task_state.last_result = payload[:result]
          task_state.last_error = nil
          if step_states[step]
            step_states[step].status = :completed
            step_states[step].last_result = payload[:result]
            step_states[step].last_error = nil
            step_states[step].attempt = task_state.attempt
          end
          ctx.merge!(payload[:ctx_snapshot] || {})
        when :task_failed
          step = payload.fetch(:step).to_sym
          task_state = task_states[step] ||= TaskState.new(step:, status: :scheduled, attempt: 0, idempotency_key: nil, last_result: nil, last_error: nil)
          task_state.status = :failed
          task_state.attempt = payload[:attempt] || task_state.attempt
          task_state.last_error = payload[:error]
          if step_states[step]
            step_states[step].status = :failed
            step_states[step].last_error = payload[:error]
            step_states[step].attempt = task_state.attempt
          end
        when :timer_scheduled
          timer_states[payload.fetch(:timer_id)] = TimerState.new(
            id: payload.fetch(:timer_id),
            step: payload[:step]&.to_sym,
            run_at: payload[:run_at],
            status: :scheduled,
            metadata: payload[:metadata]
          )
        when :timer_fired
          timer = timer_states[payload.fetch(:timer_id)]
          timer.status = :fired if timer
        when :signal_received
          signal_buffer.push(Signals::Message.new(
                               name: payload.fetch(:signal).to_sym,
                               payload: payload[:payload],
                               metadata: payload[:metadata],
                               received_at: payload[:received_at],
                               consumed: false
                             ))
        when :signal_consumed
          signal_buffer.consume(payload.fetch(:signal))
        when :workflow_completed, :workflow_failed, :workflow_cancelled
          execution_state.state = type.to_s.sub("workflow_", "")
        end
      end

      State.new(
        execution_state:,
        ctx:,
        history: events,
        step_states:,
        awaiting:,
        task_states:,
        timer_states:,
        signal_buffer:
      )
    end
  end
end
