# frozen_string_literal: true

require "thor"
require "json"

module SolidFlow
  class CLI < Thor
    desc "start WORKFLOW", "Start a workflow execution"
    option :args, type: :string, default: "{}", desc: "JSON payload with workflow input arguments"
    def start(workflow_name)
      workflow_class = SolidFlow.configuration.workflow_registry.fetch(workflow_name)
      arguments = parse_json(options[:args])

      execution = workflow_class.start(**symbolize_keys(arguments))
      say("Started execution #{execution.id}", :green)
    rescue Errors::ConfigurationError, JSON::ParserError => e
      say("Failed to start workflow: #{e.message}", :red)
      exit(1)
    end

    desc "signal EXECUTION_ID SIGNAL", "Send a signal to a workflow execution"
    option :workflow, type: :string, desc: "Workflow name (optional; inferred if omitted)"
    option :payload, type: :string, default: "{}", desc: "JSON payload for the signal"
    def signal(execution_id, signal_name)
      workflow_class = resolve_workflow(options[:workflow], execution_id)
      payload = parse_json(options[:payload])

      workflow_class.signal(execution_id, signal_name.to_sym, payload)
      say("Signal #{signal_name} enqueued for execution #{execution_id}", :green)
    rescue Errors::ConfigurationError, JSON::ParserError => e
      say("Failed to send signal: #{e.message}", :red)
      exit(1)
    end

    desc "query EXECUTION_ID QUERY", "Execute a read-only query against a workflow"
    option :workflow, type: :string, desc: "Workflow name (optional; inferred if omitted)"
    def query(execution_id, query_name)
      workflow_class = resolve_workflow(options[:workflow], execution_id)
      result = workflow_class.query(execution_id, query_name.to_sym)
      say(JSON.pretty_generate(result))
    rescue Errors::ConfigurationError => e
      say("Failed to run query: #{e.message}", :red)
      exit(1)
    end

    no_commands do
      def parse_json(string)
        return {} if string.nil? || string.strip.empty?

        JSON.parse(string)
      end

      def symbolize_keys(hash)
        return hash unless hash.respond_to?(:transform_keys)

        hash.transform_keys(&:to_sym)
      end

      def resolve_workflow(name, execution_id)
        return SolidFlow.configuration.workflow_registry.fetch(name) if name

        SolidFlow.store.with_execution(execution_id, lock: false) do |execution|
          return SolidFlow.configuration.workflow_registry.fetch(execution[:workflow])
        end
      end
    end
  end
end
