import Config

config :ourocode,
  parallel_child_count: 3,
  repeat_count: 1,
  stream_mailbox_capacity: 1_000,
  stream_mailbox_overflow_path: :drop,
  stream_mailbox_backpressure_threshold: 800,
  stream_mailbox_backpressure_behavior: :notify,
  stream_mailbox_backpressure_delay_ms: 10,
  allowed_memory_growth_mb: 64,
  stale_cleanup_timeout_ms: 30_000,
  operation_timeout_ms: 120_000,
  stream_subscription_cleanup_timeout_ms: 10_000,
  pane_state_retention_ms: 300_000
