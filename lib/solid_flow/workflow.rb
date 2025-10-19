# frozen_string_literal: true

require "active_support/core_ext/class/subclasses"
require "active_support/core_ext/object/blank"
require "set"

module SolidFlow
  # Base class that developers subclass to implement durable workflows.
  # Provides a DSL for defining steps, signals, queries, and compensations.
  class Workflow
    StepDefinition = Struct.new(
      :name,
      :task,
      :block,
      :retry_policy,
      :timeouts,
      :idempotency_key,
      :options,
      keyword_init: true
    ) do
      def task?
        task.present?
      end

      def block?
        !block.nil?
      end

      def dup
        self.class.new(
          name:,
          task:,
          block:,
          retry_policy: retry_policy.deep_dup,
          timeouts: timeouts.deep_dup,
          idempotency_key:,
          options: options.deep_dup
        )
      end
    end

    class << self
      def inherited(subclass)
        super

        SolidFlow.configuration.workflow_registry.register(subclass.workflow_name, subclass)
        subclass.instance_variable_set(:@workflow_steps, workflow_steps.map(&:dup))
        subclass.instance_variable_set(:@workflow_signals, workflow_signals.deep_dup)
        subclass.instance_variable_set(:@workflow_queries, workflow_queries.deep_dup)
        subclass.instance_variable_set(:@signal_handlers, signal_handlers.deep_dup)
        subclass.instance_variable_set(:@query_handlers, query_handlers.deep_dup)
        subclass.instance_variable_set(:@workflow_defaults, workflow_defaults.deep_dup)
        subclass.instance_variable_set(:@workflow_compensations, workflow_compensations.deep_dup)
      end

      def workflow_name(value = nil)
        if value
          normalized = value.to_s
          @workflow_name = normalized
          SolidFlow.configuration.workflow_registry.register(normalized, self)
          @workflow_name
        else
          @workflow_name ||= name || "anonymous_workflow"
        end
      end

      def workflow_steps
        @workflow_steps ||= []
      end

      def workflow_signals
        @workflow_signals ||= {}
      end

      def workflow_queries
        @workflow_queries ||= {}
      end

      def signal_handlers
        @signal_handlers ||= {}
      end

      def query_handlers
        @query_handlers ||= {}
      end

      def workflow_defaults
        @workflow_defaults ||= {
          retry: {},
          timeouts: {}
        }
      end

      def workflow_compensations
        @workflow_compensations ||= {}
      end

      def defaults(options = {})
        workflow_defaults.deep_merge!(options.deep_symbolize_keys)
      end

      def step(name, task: nil, **options, &block)
        raise ArgumentError, "step #{name} already defined" if workflow_steps.any? { |s| s.name == name.to_sym }

        retry_policy  = workflow_defaults[:retry].merge(options.delete(:retry) || {})
        timeouts      = workflow_defaults[:timeouts].merge(options.delete(:timeouts) || {})
        idempotency   = options.delete(:idempotency_key)

        workflow_steps << StepDefinition.new(
          name: name.to_sym,
          task: task&.to_sym,
          block: block,
          retry_policy: retry_policy,
          timeouts: timeouts,
          idempotency_key: idempotency,
          options: options
        )
      end

      def signal(name, buffer: true)
        workflow_signals[name.to_sym] = { buffer: }
      end

      def on_signal(name, method_name = nil, &block)
        handler =
          if method_name
            lambda { |payload| send(method_name, payload) }
          else
            block
          end

        raise ArgumentError, "on_signal requires a block or method name" unless handler

        signal_handlers[name.to_sym] = handler
      end

      def query(name)
        workflow_queries[name.to_sym] = {}
      end

      def on_query(name, method_name = nil, &block)
        handler =
          if method_name
            lambda { send(method_name) }
          else
            block
          end

        raise ArgumentError, "on_query requires a block or method name" unless handler

        query_handlers[name.to_sym] = handler
      end

      def compensate(step_name, with:)
        workflow_compensations[step_name.to_sym] = with.to_sym
      end

      def steps
        workflow_steps.dup
      end

      def signals
        workflow_signals.dup
      end

      def queries
        workflow_queries.dup
      end

      def compensations
        workflow_compensations.dup
      end

      def graph_signature
        Determinism.graph_signature(self)
      end

      def start(**input)
        SolidFlow.instrument("solidflow.execution.start", workflow: workflow_name, input:)
        signature = graph_signature
        SolidFlow.store.start_execution(
          workflow_class: self,
          input: input,
          graph_signature: signature
        )
      end

      def signal(execution_id, signal_name, payload = {})
        raise Errors::UnknownSignal, signal_name unless signal_handlers.key?(signal_name.to_sym) || workflow_signals.key?(signal_name.to_sym)

        normalized_payload = payload.is_a?(Hash) ? payload.deep_symbolize_keys : payload

        SolidFlow.store.signal_execution(
          execution_id:,
          workflow_class: self,
          signal_name: signal_name.to_sym,
          payload: normalized_payload
        )
      end

      def query(execution_id, query_name)
        handler = query_handlers.fetch(query_name.to_sym) do
          raise Errors::UnknownQuery, query_name
        end

        SolidFlow.store.query_execution(
          execution_id:,
          workflow_class: self
        ) do |state|
          workflow = new(ctx: state.ctx, execution: state.execution_state, history: state.history)
          workflow.instance_exec(&handler)
        end
      end
    end

    attr_reader :ctx, :execution, :history

    def initialize(ctx:, execution:, history: [])
      @ctx         = ctx.with_indifferent_access
      @execution   = execution
      @history     = history
      @wait_context = nil
    end

    def wait
      @wait_context ||= Wait::Context.new
    end

    def reset_wait_context!
      @wait_context = Wait::Context.new
    end

    def consume_wait_instructions
      instructions = @wait_context&.instructions || []
      @wait_context = nil
      instructions
    end

    def apply_signal(name, payload)
      handler = self.class.signal_handlers[name.to_sym]
      raise Errors::UnknownSignal, name unless handler

      instance_exec(payload.with_indifferent_access, &handler)
    end

    def signal_defined?(name)
      self.class.signal_handlers.key?(name.to_sym) || self.class.workflow_signals.key?(name.to_sym)
    end

    def query_defined?(name)
      self.class.query_handlers.key?(name.to_sym)
    end

    def cancel!(reason = "cancelled")
      @cancelled = true
      raise Errors::Cancelled, reason
    end

    def cancelled?
      !!@cancelled
    end
  end
end
