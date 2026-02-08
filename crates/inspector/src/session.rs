//! Inspector session management.
//!
//! This module provides the `InspectorSession` which ties together the
//! V8 inspector, client, channel, and server into a single debugging session.
//!
//! ## Shared Server Architecture
//!
//! SpacetimeDB creates multiple V8 isolates for parallel execution. To support
//! debugging, we use a SHARED inspector server architecture:
//!
//! - Only ONE WebSocket server runs on the configured port (e.g., 9229)
//! - All V8 isolates share the same server's broadcast channel
//! - The first isolate to start creates the server, others connect to it
//! - This allows debugging the first/main V8 instance

use crate::client::{PauseMessagePump, SpacetimeInspectorChannel, SpacetimeInspectorClient, InspectorClientConfig};
use crate::server::{InspectorServer, InspectorServerConfig};
use crate::InspectorConfig;
use anyhow::Result;
use std::sync::{Arc, Mutex, OnceLock};
use tokio::runtime::Runtime;
use tokio::sync::{broadcast, mpsc};

/// Global shared inspector server state.
///
/// This ensures only ONE inspector server runs, shared across all V8 isolates.
/// The first isolate to start the inspector creates the server, others connect to it.
///
/// The `from_debugger_tx` is swappable so that when V8 workers are replaced
/// (e.g., during module updates), the new worker can create a fresh channel
/// and the server's connection handlers will use the new sender.
struct SharedInspectorServer {
    /// Broadcast sender for outgoing CDP messages (shared by all isolates).
    broadcast_tx: broadcast::Sender<String>,
    /// Swappable sender for incoming CDP messages (from debugger to V8).
    /// Connection handlers clone this Arc and lock it each time they send.
    /// New V8 isolates swap in a fresh sender when they connect.
    from_debugger_tx: Arc<Mutex<mpsc::UnboundedSender<String>>>,
    /// Keep the server thread handle alive (prevents drop).
    _server: Mutex<Option<InspectorServer>>,
}

/// Global shared server instance.
static SHARED_SERVER: OnceLock<SharedInspectorServer> = OnceLock::new();

use v8::inspector::{
    Channel, StringView, V8Inspector, V8InspectorClient, V8InspectorClientTrustLevel,
    V8InspectorSession as V8Session,
};
use v8::{Context, Isolate, Local};

/// Context group ID for SpacetimeDB modules.
const CONTEXT_GROUP_ID: i32 = 1;

/// An inspector session for debugging a V8 isolate.
///
/// This struct owns and coordinates all the inspector components:
/// - `V8Inspector` - The V8 inspector instance
/// - `V8InspectorClient` - Handles pause/resume and console messages
/// - `Channel` - Routes CDP messages
/// - `InspectorServer` - WebSocket server for debugger connections
pub struct InspectorSession {
    /// The V8 inspector instance (owns the client).
    inspector: Option<V8Inspector>,

    /// The inspector session (connected to channel).
    session: Option<V8Session>,

    /// Broadcast sender for outgoing CDP messages (to debuggers).
    broadcast_tx: Option<broadcast::Sender<String>>,

    /// Shared receiver for incoming CDP messages (from debugger).
    shared_incoming_rx: Arc<Mutex<Option<mpsc::UnboundedReceiver<String>>>>,

    /// Reference to the pause pump for setting the session pointer after connect.
    pause_pump: Option<Arc<Mutex<Option<PauseMessagePump>>>>,

    /// Configuration.
    config: InspectorConfig,
}

impl InspectorSession {
    /// Create a new inspector session with the given configuration.
    pub fn new(config: InspectorConfig) -> Self {
        Self {
            inspector: None,
            session: None,
            broadcast_tx: None,
            shared_incoming_rx: Arc::new(Mutex::new(None)),
            pause_pump: None,
            config,
        }
    }

    /// Initialize the inspector for the given V8 isolate.
    ///
    /// This must be called before any JavaScript is executed if you want
    /// to be able to set breakpoints in the initial code.
    ///
    /// If `start_server_sync()` was called first, uses the broadcast sender from the server.
    /// Otherwise creates a standalone broadcast channel.
    pub fn initialize(&mut self, isolate: &mut Isolate) {
        let broadcast_tx = self.broadcast_tx.clone().unwrap_or_else(|| {
            let (tx, _) = broadcast::channel(1024);
            tx
        });

        let client_config = InspectorClientConfig {
            break_on_start: self.config.break_on_start,
        };
        let client_impl = SpacetimeInspectorClient::new(client_config, broadcast_tx.clone());

        let pump = PauseMessagePump::new(self.shared_incoming_rx.clone());
        client_impl.set_pause_pump(pump);

        self.pause_pump = Some(client_impl.pause_pump());

        let client = V8InspectorClient::new(Box::new(client_impl));
        let inspector = V8Inspector::create(isolate, client);

        self.inspector = Some(inspector);
        self.broadcast_tx = Some(broadcast_tx);

        log::info!(
            "V8 Inspector initialized (port: {}, break_on_start: {})",
            self.config.port,
            self.config.break_on_start
        );
    }

    /// Register a V8 context with the inspector.
    ///
    /// This should be called after creating a context and before executing
    /// any code in it.
    pub fn context_created(&mut self, context: Local<Context>, name: &str) {
        if let Some(ref mut inspector) = self.inspector {
            let name_view = StringView::from(name.as_bytes());
            let aux_data = StringView::empty();
            inspector.context_created(context, CONTEXT_GROUP_ID, name_view, aux_data);
            log::debug!("Inspector: Context '{}' registered", name);
        }
    }

    /// Notify the inspector that a context is being destroyed.
    pub fn context_destroyed(&mut self, context: Local<Context>) {
        if let Some(ref mut inspector) = self.inspector {
            inspector.context_destroyed(context);
        }
    }

    /// Connect a debugging session.
    ///
    /// This creates the V8InspectorSession which handles CDP message dispatch.
    pub fn connect(&mut self) {
        let broadcast_tx = match self.broadcast_tx.clone() {
            Some(tx) => tx,
            None => {
                log::warn!("Cannot connect inspector session: no broadcast channel");
                return;
            }
        };

        if let Some(ref inspector) = self.inspector {
            let channel_impl = SpacetimeInspectorChannel::new(broadcast_tx);
            let channel = Channel::new(Box::new(channel_impl));

            let state = StringView::empty();
            let session = inspector.connect(
                CONTEXT_GROUP_ID,
                channel,
                state,
                V8InspectorClientTrustLevel::FullyTrusted,
            );

            // IMPORTANT: Move session into self.session FIRST, then take the pointer.
            // The raw pointer must point to the session's final resting place (inside self),
            // not a temporary stack variable that will be invalidated after the move.
            self.session = Some(session);
            log::info!("Inspector session connected");

            // Now set the session pointer on the pause pump from the stored location
            if let Some(ref pump_arc) = self.pause_pump {
                if let Ok(mut pump_guard) = pump_arc.lock() {
                    if let Some(ref mut pump) = *pump_guard {
                        if let Some(ref session) = self.session {
                            // Safety: The session is owned by self and will outlive the pump
                            unsafe {
                                pump.set_session(session);
                            }
                        }
                    }
                }
            }
        }
    }

    /// Disconnect the debugging session.
    pub fn disconnect(&mut self) {
        self.session = None;
        log::info!("Inspector session disconnected");
    }

    /// Dispatch a CDP message from the debugger to V8.
    pub fn dispatch_message(&mut self, message: &str) {
        if let Some(ref session) = self.session {
            let message_view = StringView::from(message.as_bytes());
            session.dispatch_protocol_message(message_view);
        }
    }

    /// Schedule a pause on the next statement.
    ///
    /// This is used for `--inspect-brk` functionality.
    pub fn schedule_pause_on_next_statement(&mut self, reason: &str) {
        if let Some(ref session) = self.session {
            let reason_view = StringView::from(reason.as_bytes());
            let detail_view = StringView::empty();
            session.schedule_pause_on_next_statement(reason_view, detail_view);
        }
    }

    /// Check if a CDP method can be dispatched.
    pub fn can_dispatch_method(method: &str) -> bool {
        let method_view = StringView::from(method.as_bytes());
        V8Session::can_dispatch_method(method_view)
    }

    /// Start the WebSocket server for debugger connections.
    ///
    /// Uses a SHARED server architecture: only the first V8 isolate creates
    /// the server, subsequent isolates connect to the shared server.
    ///
    /// This spawns a dedicated thread with its own tokio runtime to avoid
    /// conflicts with V8's event loop. The broadcast channel allows
    /// communication between the server thread and the V8 thread.
    pub fn start_server_sync(&mut self) -> Result<()> {
        // Check if a shared server already exists
        if let Some(shared) = SHARED_SERVER.get() {
            log::info!("V8 Inspector: Connecting to existing shared server on port {}", self.config.port);
            self.broadcast_tx = Some(shared.broadcast_tx.clone());

            // Create a fresh channel and swap the sender in the shared server
            let (new_tx, new_rx) = mpsc::unbounded_channel::<String>();
            {
                let mut guard = shared.from_debugger_tx.lock().unwrap();
                *guard = new_tx;
            }
            if let Ok(mut my_guard) = self.shared_incoming_rx.lock() {
                *my_guard = Some(new_rx);
            }
            return Ok(());
        }

        let server_config = InspectorServerConfig {
            host: self.config.host.clone(),
            port: self.config.port,
        };

        let (result_tx, result_rx) = std::sync::mpsc::channel();

        // Spawn a dedicated thread for the inspector server
        let _server_thread = std::thread::spawn(move || {
            let rt = match Runtime::new() {
                Ok(rt) => rt,
                Err(e) => {
                    let _ = result_tx.send(Err(anyhow::anyhow!("Failed to create runtime: {}", e)));
                    return;
                }
            };

            rt.block_on(async {
                let mut server = InspectorServer::new(server_config);
                match server.start().await {
                    Ok((broadcast_tx, shared_tx, from_debugger_rx)) => {
                        let _ = result_tx.send(Ok((broadcast_tx, shared_tx, from_debugger_rx, server)));
                        // Keep the runtime and server alive
                        loop {
                            tokio::time::sleep(tokio::time::Duration::from_secs(3600)).await;
                        }
                    }
                    Err(e) => {
                        let _ = result_tx.send(Err(e));
                    }
                }
            });
        });

        let (broadcast_tx, shared_tx, from_debugger_rx, server) = result_rx
            .recv_timeout(std::time::Duration::from_secs(5))
            .map_err(|_| anyhow::anyhow!("Timeout waiting for inspector server"))??;

        let shared = SharedInspectorServer {
            broadcast_tx: broadcast_tx.clone(),
            from_debugger_tx: shared_tx,
            _server: Mutex::new(Some(server)),
        };

        if SHARED_SERVER.set(shared).is_ok() {
            log::info!("V8 Inspector: Created shared server on port {}", self.config.port);
            self.broadcast_tx = Some(broadcast_tx);

            if let Ok(mut my_guard) = self.shared_incoming_rx.lock() {
                *my_guard = Some(from_debugger_rx);
            }
        } else {
            // Another thread beat us - use their shared server instead
            log::info!("V8 Inspector: Another isolate created the shared server first");
            if let Some(shared) = SHARED_SERVER.get() {
                self.broadcast_tx = Some(shared.broadcast_tx.clone());
                let (new_tx, new_rx) = mpsc::unbounded_channel::<String>();
                {
                    let mut guard = shared.from_debugger_tx.lock().unwrap();
                    *guard = new_tx;
                }
                if let Ok(mut my_guard) = self.shared_incoming_rx.lock() {
                    *my_guard = Some(new_rx);
                }
            }
        }

        Ok(())
    }

    /// Process pending CDP messages from the debugger.
    ///
    /// This should be called periodically from the V8 thread.
    pub fn process_messages(&mut self) {
        let messages: Vec<String> = if let Ok(mut guard) = self.shared_incoming_rx.lock() {
            if let Some(ref mut rx) = *guard {
                let mut msgs = Vec::new();
                while let Ok(message) = rx.try_recv() {
                    log::debug!("Inspector: received CDP message: {}", &message[..message.len().min(200)]);
                    msgs.push(message);
                }
                msgs
            } else {
                Vec::new()
            }
        } else {
            log::warn!("Inspector: failed to lock shared_incoming_rx");
            Vec::new()
        };

        for message in messages {
            self.dispatch_message(&message);
        }
    }

    /// Check if the inspector is initialized.
    pub fn is_initialized(&self) -> bool {
        self.inspector.is_some()
    }

    /// Check if a session is connected.
    pub fn is_connected(&self) -> bool {
        self.session.is_some()
    }
}

/// Custom Drop implementation to ensure proper cleanup order.
///
/// The V8InspectorSession internally holds a reference to the V8Inspector.
/// We must drop the session before the inspector to avoid dangling pointers.
impl Drop for InspectorSession {
    fn drop(&mut self) {
        // Drop session first - it references the inspector
        self.session = None;
        self.inspector = None;
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_session_creation() {
        let config = InspectorConfig::new(9229);
        let session = InspectorSession::new(config);
        assert!(!session.is_initialized());
        assert!(!session.is_connected());
    }

    #[test]
    fn test_can_dispatch_method() {
        assert!(InspectorSession::can_dispatch_method("Debugger.enable"));
        assert!(InspectorSession::can_dispatch_method("Runtime.enable"));
        assert!(InspectorSession::can_dispatch_method("Debugger.setBreakpointByUrl"));
    }
}
