require "spec_helper"

RSpec.describe SolidFlow::Determinism do
  let(:workflow_class) do
    Class.new(SolidFlow::Workflow) do
      workflow_name "DeterministicWorkflow"

      step :a, task: :task_a
      step :b do
        ctx[:value] = 1
      end
    end
  end

  it "computes deterministic graph signature" do
    first = described_class.graph_signature(workflow_class)
    second = described_class.graph_signature(workflow_class)
    expect(first).to eq(second)
  end

  it "detects mismatched signatures" do
    signature = described_class.graph_signature(workflow_class)
    allow(SolidFlow::Determinism).to receive(:graph_signature).and_return("different")

    expect do
      described_class.assert_graph!(workflow_class, signature)
    end.to raise_error(SolidFlow::Errors::NonDeterministicWorkflowError)
  end
end
