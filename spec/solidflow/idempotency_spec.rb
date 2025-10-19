require "ostruct"
require "spec_helper"

RSpec.describe SolidFlow::Idempotency do
  let(:workflow_class) do
    Class.new(SolidFlow::Workflow) do
      workflow_name "TestWorkflow"
      step :one
    end
  end

  let(:execution) { OpenStruct.new(id: "exec-123") }
  let(:workflow) { workflow_class.new(ctx: {}, execution:, history: []) }
  let(:step_definition) { workflow_class.steps.first }

  it "uses provided string keys verbatim" do
    key = described_class.evaluate("abc", workflow: workflow, step: step_definition)
    expect(key).to eq("abc")
  end

  it "evaluates proc keys in workflow context" do
    proc_step = step_definition.dup
    proc_step.idempotency_key = -> { "computed:#{execution.id}" }
    key = described_class.evaluate(proc_step.idempotency_key, workflow: workflow, step: proc_step)
    expect(key).to eq("computed:exec-123")
  end

  it "falls back to deterministic default" do
    key = described_class.evaluate(nil, workflow: workflow, step: step_definition)
    expect(key).to match(/\A[0-9a-f]{64}\z/)
  end
end
