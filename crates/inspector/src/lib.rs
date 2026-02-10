//! V8 Inspector support for SpacetimeDB TypeScript module debugging.
//!
//! This crate provides the infrastructure to enable source-level debugging
//! of TypeScript reducers running in SpacetimeDB's V8 runtime.
//!
//! # Architecture
//!
//! ```text
//! ┌─────────────────────────────────────────────────────────────┐
//! │ SpacetimeDB Server (--inspect=9229)                         │
//! │                                                             │
//! │  ┌─────────────────┐     ┌─────────────────────────────────┐│
//! │  │ V8 Isolate      │◄───►│ InspectorClient                 ││
//! │  │ (runs TS)       │     │  - pause/resume control         ││
//! │  └─────────────────┘     │  - console message routing      ││
//! │                          └──────────────┬──────────────────┘│
//! │                                         │                   │
//! │                          ┌──────────────▼──────────────────┐│
//! │                          │ InspectorServer                 ││
//! │                          │  - WebSocket (ws://host:port)   ││
//! │                          │  - HTTP /json/list endpoint     ││
//! │                          └──────────────┬──────────────────┘│
//! └─────────────────────────────────────────┼───────────────────┘
//!                                           │ CDP Protocol
//!                              ┌────────────▼────────────┐
//!                              │ Debugger Client         │
//!                              │  - Chrome DevTools      │
//!                              │  - Admin App            │
//!                              │  - VS Code              │
//!                              └─────────────────────────┘
//! ```
//!
//! # Usage
//!
//! Start SpacetimeDB with the `--inspect` flag:
//!
//! ```bash
//! spacetime start --inspect=9229
//! ```
//!
//! Then connect a debugger to `ws://localhost:9229`.

mod client;
mod server;
mod session;

pub use client::{PauseMessagePump, SpacetimeInspectorChannel, SpacetimeInspectorClient};
pub use server::{InspectorServer, InspectorServerConfig};
pub use session::InspectorSession;

/// Overflow behavior for queued inbound debugger commands.
#[derive(Debug, Clone, Copy, Default, PartialEq, Eq)]
pub enum CommandQueueOverflowPolicy {
    /// Drop oldest queued commands until the new command fits.
    #[default]
    DropOldestWithWarn,
    /// Drop the newest incoming command when the queue is full.
    DropNewestWithWarn,
}

/// Configuration for enabling V8 inspector debugging.
#[derive(Debug, Clone)]
pub struct InspectorConfig {
    /// Port to listen on for debugger connections.
    pub port: u16,

    /// Whether to pause before the first statement (like `--inspect-brk`).
    pub break_on_start: bool,

    /// Host to bind the inspector server to.
    pub host: String,

    /// Maximum number of inbound debugger commands queued when no active receiver exists.
    pub max_pending_debugger_commands: usize,

    /// Maximum total bytes of inbound debugger commands queued when no active receiver exists.
    pub max_pending_command_bytes: usize,

    /// Behavior when the pending inbound command queue reaches capacity.
    pub command_queue_overflow_policy: CommandQueueOverflowPolicy,
}

impl Default for InspectorConfig {
    fn default() -> Self {
        Self {
            port: 9229,
            break_on_start: false,
            host: "127.0.0.1".to_string(),
            max_pending_debugger_commands: 256,
            max_pending_command_bytes: 1024 * 1024,
            command_queue_overflow_policy: CommandQueueOverflowPolicy::DropOldestWithWarn,
        }
    }
}

impl InspectorConfig {
    /// Create a new config with the given port.
    pub fn new(port: u16) -> Self {
        Self {
            port,
            ..Default::default()
        }
    }

    /// Create a new config that breaks on first statement.
    pub fn new_break_on_start(port: u16) -> Self {
        Self {
            port,
            break_on_start: true,
            ..Default::default()
        }
    }
}
