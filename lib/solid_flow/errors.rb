# frozen_string_literal: true

module SolidFlow
  module Errors
    # Base error for all SolidFlow failures.
    class SolidFlowError < StandardError; end

    class ConfigurationError < SolidFlowError; end
    class DeterminismError   < SolidFlowError; end
    class ExecutionNotFound  < SolidFlowError; end
    class Cancelled          < SolidFlowError; end
    class TimeoutError       < SolidFlowError; end
    class TaskFailure        < SolidFlowError
      attr_reader :details

      def initialize(message = nil, details: nil)
        @details = details
        super(message || "Task execution failed")
      end
    end

    class NonDeterministicWorkflowError < DeterminismError
      attr_reader :expected, :actual

      def initialize(expected:, actual:)
        @expected = expected
        @actual   = actual
        super("Workflow definition diverged from persisted graph signature (expected: #{expected}, actual: #{actual})")
      end
    end

    class UnknownSignal < SolidFlowError
      def initialize(signal)
        super("Unknown signal `#{signal}`")
      end
    end

    class UnknownQuery < SolidFlowError
      def initialize(query)
        super("Unknown query `#{query}`")
      end
    end

    class InvalidStep < SolidFlowError
      def initialize(step)
        super("Step `#{step}` is not defined on this workflow")
      end
    end

    class WaitInstructionError < SolidFlowError; end
  end
end
