# frozen_string_literal: true

require "digest"

module SolidFlow
  module Idempotency
    module_function

    def evaluate(key, workflow:, step:)
      case key
      when Proc
        workflow.instance_exec(&key).to_s
      when Symbol
        workflow.public_send(key).to_s
      when String
        key
      when Array
        key.compact.map(&:to_s).join(":")
      when nil
        default(workflow.execution.id, step.name)
      else
        key.to_s
      end
    end

    def default(execution_id, step_name, attempt = 0)
      Digest::SHA256.hexdigest([execution_id, step_name, attempt].join(":"))
    end

    def digest(*parts)
      Digest::SHA256.hexdigest(parts.flatten.compact.map(&:to_s).join("|"))
    end
  end
end
