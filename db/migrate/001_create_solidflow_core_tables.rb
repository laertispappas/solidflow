class CreateSolidflowCoreTables < ActiveRecord::Migration[7.1]
  def change
    enable_extension "pgcrypto" unless extension_enabled?("pgcrypto")

    create_table :solidflow_executions, id: :uuid do |t|
      t.string  :workflow, null: false
      t.string  :state, null: false, default: "running"
      t.jsonb   :ctx, null: false, default: {}
      t.string  :cursor_step
      t.integer :cursor_index, null: false, default: 0
      t.string  :graph_signature
      t.jsonb   :metadata, null: false, default: {}
      t.jsonb   :last_error
      t.string  :shard_key
      t.string  :account_id
      t.datetime :started_at, null: false, default: -> { "CURRENT_TIMESTAMP" }
      t.timestamps
    end

    add_index :solidflow_executions, :workflow
    add_index :solidflow_executions, %i[state workflow]
    add_index :solidflow_executions, :shard_key
    add_index :solidflow_executions, :account_id

    create_table :solidflow_events, id: :uuid do |t|
      t.uuid     :execution_id, null: false
      t.integer  :sequence, null: false
      t.string   :event_type, null: false
      t.jsonb    :payload, null: false, default: {}
      t.string   :idempotency_key
      t.datetime :recorded_at, null: false, default: -> { "CURRENT_TIMESTAMP" }
      t.timestamps
    end

    add_index :solidflow_events, %i[execution_id sequence], unique: true
    add_index :solidflow_events, :event_type
    add_index :solidflow_events, %i[execution_id idempotency_key], unique: true, where: "idempotency_key IS NOT NULL"
    add_foreign_key :solidflow_events, :solidflow_executions, column: :execution_id

    create_table :solidflow_timers, id: :uuid do |t|
      t.uuid     :execution_id, null: false
      t.string   :step, null: false
      t.datetime :run_at, null: false
      t.string   :status, null: false, default: "scheduled"
      t.jsonb    :instruction, null: false, default: {}
      t.jsonb    :metadata, null: false, default: {}
      t.datetime :fired_at
      t.timestamps
    end

    add_index :solidflow_timers, :execution_id
    add_index :solidflow_timers, %i[status run_at]
    add_foreign_key :solidflow_timers, :solidflow_executions, column: :execution_id

    create_table :solidflow_signal_messages, id: :uuid do |t|
      t.uuid     :execution_id, null: false
      t.string   :signal_name, null: false
      t.jsonb    :payload, null: false, default: {}
      t.jsonb    :metadata, null: false, default: {}
      t.string   :status, null: false, default: "pending"
      t.datetime :received_at, null: false, default: -> { "CURRENT_TIMESTAMP" }
      t.datetime :consumed_at
      t.timestamps
    end

    add_index :solidflow_signal_messages, :execution_id
    add_index :solidflow_signal_messages, %i[execution_id status]
    add_index :solidflow_signal_messages, %i[execution_id signal_name status], name: "index_solidflow_signals_lookup"
    add_foreign_key :solidflow_signal_messages, :solidflow_executions, column: :execution_id
  end
end
