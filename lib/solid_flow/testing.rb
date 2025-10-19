# frozen_string_literal: true

module SolidFlow
  module Testing
    module_function

    # Runs an execution synchronously until it reaches a terminal state or the
    # provided iteration limit. Useful for unit-style workflow specs.
    def drain_execution(execution_id, max_iterations: 100)
      runner = SolidFlow::Runner.new
      max_iterations.times do
        runner.run(execution_id)

        status = SolidFlow.store.with_execution(execution_id, lock: false) do |execution|
          execution[:state]
        end

        break unless status == "running"
      end
    end

    def start_and_drain(workflow_class, **input)
      execution = workflow_class.start(**input)
      drain_execution(execution.id)
      execution
    end
  end
end
