require "spec_helper"

RSpec.describe SolidFlow::Wait::Context do
  subject(:context) { described_class.new }

  it "collects timer instructions" do
    instruction = context.for(seconds: 5)
    expect(instruction.type).to eq(:timer)
    expect(context.instructions).to include(instruction)
  end

  it "collects signal instructions" do
    instruction = context.for_signal(:payment)
    expect(instruction.type).to eq(:signal)
    expect(context.instructions.last.options[:signal]).to eq(:payment)
  end

  it "raises when missing timing information" do
    expect { context.for }.to raise_error(ArgumentError)
  end
end
