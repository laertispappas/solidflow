# frozen_string_literal: true

require "json"

module SolidFlow
  module Determinism
    module_function

    def graph_signature(workflow_class)
      payload = {
        workflow: workflow_class.name,
        steps: workflow_class.steps.map do |step|
          {
            name: step.name,
            task: step.task,
            block: step.block? ? "block" : nil,
            retry: step.retry_policy,
            timeouts: step.timeouts,
            options: step.options
          }
        end,
        signals: workflow_class.signals.keys.map(&:to_s).sort,
        queries: workflow_class.queries.keys.map(&:to_s).sort,
        compensations: workflow_class.compensations.transform_keys(&:to_s).transform_values(&:to_s).sort.to_h
      }

      Digest::SHA256.hexdigest(JSON.generate(payload))
    end

    def assert_graph!(workflow_class, persisted_signature)
      signature = graph_signature(workflow_class)
      return signature unless persisted_signature

      return signature if signature == persisted_signature

      raise Errors::NonDeterministicWorkflowError.new(expected: persisted_signature, actual: signature)
    end
  end
end
