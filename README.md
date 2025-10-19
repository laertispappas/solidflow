# SolidFlow

**SolidFlow** — Durable workflows for Ruby and Rails. Deterministic workflows, event‑sourced history, timers, signals, tasks, and SAGA compensations. Backed by ActiveJob and ActiveRecord. Production‑ready, scalable, and extensible.

## Installation

Add this line to your application's Gemfile:

```ruby
gem "solidflow", path: "solidflow"
```

Then run `bundle install` and install the migrations:

```bash
bin/rails solidflow:install:migrations
bin/rails db:migrate
```

## Quick Start

Define a workflow and a task:

```ruby
class ReserveInventoryTask < SolidFlow::Task
  def perform(order_id:)
    Inventory.reserve(order_id: order_id)
  end
end

class OrderFulfillmentWorkflow < SolidFlow::Workflow
  signal :payment_captured

  step :reserve_inventory, task: :reserve_inventory_task

  step :await_payment do
    wait.for(seconds: 30)
    wait.for_signal(:payment_captured) unless ctx[:payment_received]
  end

  on_signal :payment_captured do |payload|
    ctx[:payment_received] = true
    ctx[:txn_id] = payload.fetch("txn_id")
  end
end
```

Kick off an execution:

```ruby
execution = OrderFulfillmentWorkflow.start(order_id: "ORD-1")
OrderFulfillmentWorkflow.signal(execution.id, :payment_captured, txn_id: "txn-123")
```

## CLI

```bash
bin/solidflow start OrderFulfillmentWorkflow --args '{"order_id":"ORD-1"}'
bin/solidflow signal <execution_id> payment_captured --payload '{"txn_id":"txn-123"}'
bin/solidflow query <execution_id> status
```

## Testing

```ruby
execution = SolidFlow::Testing.start_and_drain(OrderFulfillmentWorkflow, order_id: "ORD-1")
expect(execution.state).to eq("completed")
```

See `solid_flow_instructions.md` for the full architecture and feature specification.
