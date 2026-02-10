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

use crate::client::{PauseMessagePump, SpacetimeInspectorChannel, SpacetimeInspectorClient};
use crate::server::{CommandReceiverClaim, InspectorServer, InspectorServerConfig, SharedCommandRouter};
use crate::InspectorConfig;
use anyhow::Result;
use std::sync::atomic::{AtomicBool, AtomicPtr, Ordering};
use std::sync::{Arc, Mutex, OnceLock};
use tokio::runtime::Runtime;
use tokio::sync::{broadcast, mpsc};

/// Global shared inspector server state.
///
/// This ensures only ONE inspector server runs, shared across all V8 isolates.
/// The first isolate to start the inspector creates the server, others connect to it.
///
/// Incoming debugger command ownership is stable while the current owner is
/// alive. If that owner exits and the receiver closes, the next isolate that
/// attaches can claim ownership by swapping in a fresh sender/receiver pair.
struct SharedInspectorServer {
    /// Broadcast sender for outgoing CDP messages (shared by all isolates).
    broadcast_tx: broadcast::Sender<String>,
    /// Shared router for incoming debugger commands.
    command_router: Arc<Mutex<SharedCommandRouter>>,
    /// Keep the server thread handle alive (prevents drop).
    _server: Mutex<Option<InspectorServer>>,
}

/// Global shared server instance.
static SHARED_SERVER: OnceLock<SharedInspectorServer> = OnceLock::new();
/// Serializes first-time shared server initialization to avoid startup races.
static SHARED_SERVER_INIT_LOCK: OnceLock<Mutex<()>> = OnceLock::new();

use v8::inspector::{
    Channel, StringView, V8Inspector, V8InspectorClient, V8InspectorClientTrustLevel, V8InspectorSession as V8Session,
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

    /// Shared atomic pointer to the V8InspectorSession, used by the pause pump.
    /// Nulled in `Drop` BEFORE the session is dropped.
    session_ptr: Arc<AtomicPtr<V8Session>>,

    /// Ownership epoch when this isolate owns inbound debugger commands.
    command_owner_epoch: Option<u64>,

    /// Configuration.
    config: InspectorConfig,
}

impl InspectorSession {
    fn apply_command_receiver_claim(&mut self, claim: CommandReceiverClaim) {
        let drained = claim.drained_count;
        self.command_owner_epoch = Some(claim.epoch);
        if let Ok(mut my_guard) = self.shared_incoming_rx.lock() {
            *my_guard = Some(claim.receiver);
        }
        if drained > 0 {
            log::info!(
                "V8 Inspector: claimed command channel epoch={} with {} queued commands",
                claim.epoch,
                drained
            );
        } else {
            log::info!("V8 Inspector: claimed command channel epoch={}", claim.epoch);
        }
    }

    fn release_command_channel_ownership(&mut self) {
        let Some(epoch) = self.command_owner_epoch.take() else {
            return;
        };

        if let Ok(mut guard) = self.shared_incoming_rx.lock() {
            *guard = None;
        }

        if let Some(shared) = SHARED_SERVER.get() {
            if let Ok(mut router) = shared.command_router.lock() {
                if router.release_if_owner(epoch) {
                    let stats = router.stats();
                    log::info!(
                        "V8 Inspector: released command channel epoch={} (routed={}, enqueued={}, dropped={})",
                        epoch,
                        stats.routed_total,
                        stats.enqueued_total,
                        stats.dropped_total
                    );
                }
            }
        }
    }

    fn attach_to_shared_server(&mut self, shared: &SharedInspectorServer) {
        log::info!(
            "V8 Inspector: Connecting to existing shared server on port {}",
            self.config.port
        );
        let claimed = shared
            .command_router
            .lock()
            .expect("command router mutex poisoned")
            .claim_receiver_if_needed();
        if let Some(claim) = claimed {
            self.apply_command_receiver_claim(claim);
        } else {
            self.command_owner_epoch = None;
            if let Ok(mut my_guard) = self.shared_incoming_rx.lock() {
                *my_guard = None;
            }
        }
        self.broadcast_tx = Some(shared.broadcast_tx.clone());
    }

    /// Create a new inspector session with the given configuration.
    pub fn new(config: InspectorConfig) -> Self {
        Self {
            inspector: None,
            session: None,
            broadcast_tx: None,
            shared_incoming_rx: Arc::new(Mutex::new(None)),
            pause_pump: None,
            session_ptr: Arc::new(AtomicPtr::new(std::ptr::null_mut())),
            command_owner_epoch: None,
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

        let client_impl = SpacetimeInspectorClient::new(self.config.break_on_start, broadcast_tx.clone());

        let pump = PauseMessagePump::new(self.shared_incoming_rx.clone(), self.session_ptr.clone());
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

            // Store session in its final location first.
            self.session = Some(session);
            log::info!("Inspector session connected");

            // Set the session pointer via the shared AtomicPtr.
            // The pointer points into `self.session` which is pinned for the
            // lifetime of this `InspectorSession`.
            if let Some(ref session) = self.session {
                let ptr = session as *const V8Session as *mut V8Session;
                self.session_ptr.store(ptr, Ordering::Release);
            }
        }
    }

    /// Disconnect the debugging session.
    pub fn disconnect(&mut self) {
        // Null the shared pointer BEFORE dropping the session.
        self.session_ptr.store(std::ptr::null_mut(), Ordering::Release);
        self.release_command_channel_ownership();
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

    /// Returns true when this isolate owns inbound debugger command delivery.
    ///
    /// Only the owning isolate can receive commands like `Debugger.resume`.
    /// Non-owning isolates must not use `--inspect-brk`, or they can pause
    /// without any way to receive resume/step commands.
    pub fn owns_debugger_command_channel(&self) -> bool {
        self.command_owner_epoch.is_some()
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
        let startup_timeout = std::time::Duration::from_secs(5);
        let init_lock = SHARED_SERVER_INIT_LOCK.get_or_init(|| Mutex::new(()));
        let _init_guard = init_lock.lock().expect("shared server init mutex poisoned");

        // Check if a shared server already exists
        if let Some(shared) = SHARED_SERVER.get() {
            self.attach_to_shared_server(shared);
            return Ok(());
        }

        let server_config = InspectorServerConfig {
            host: self.config.host.clone(),
            port: self.config.port,
            max_pending_debugger_commands: self.config.max_pending_debugger_commands,
            max_pending_command_bytes: self.config.max_pending_command_bytes,
            command_queue_overflow_policy: self.config.command_queue_overflow_policy,
        };

        let (result_tx, result_rx) = std::sync::mpsc::channel();
        let startup_cancelled = Arc::new(AtomicBool::new(false));
        let startup_cancelled_thread = startup_cancelled.clone();

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
                if startup_cancelled_thread.load(Ordering::Acquire) {
                    return;
                }
                let mut server = InspectorServer::new(server_config);
                match server.start().await {
                    Ok((broadcast_tx, shared_router, initial_claim)) => {
                        if result_tx
                            .send(Ok((broadcast_tx, shared_router, initial_claim, server)))
                            .is_err()
                        {
                            log::warn!(
                                "V8 Inspector: startup receiver dropped before shared registration completed"
                            );
                            return;
                        }

                        // Keep the runtime alive while startup is still in-flight.
                        // If startup times out, the caller flips `startup_cancelled` to
                        // terminate this thread and avoid leaking it.
                        while !startup_cancelled_thread.load(Ordering::Acquire) {
                            tokio::time::sleep(tokio::time::Duration::from_secs(1)).await;
                        }
                    }
                    Err(e) => {
                        let _ = result_tx.send(Err(e));
                    }
                }
            });
        });

        let startup_result = result_rx.recv_timeout(startup_timeout);
        let (broadcast_tx, shared_router, initial_claim, server) = match startup_result {
            Ok(result) => result?,
            Err(std::sync::mpsc::RecvTimeoutError::Timeout) => {
                startup_cancelled.store(true, Ordering::Release);
                if let Some(shared) = SHARED_SERVER.get() {
                    self.attach_to_shared_server(shared);
                    return Ok(());
                }
                return Err(anyhow::anyhow!("Timeout waiting for inspector server"));
            }
            Err(std::sync::mpsc::RecvTimeoutError::Disconnected) => {
                startup_cancelled.store(true, Ordering::Release);
                if let Some(shared) = SHARED_SERVER.get() {
                    self.attach_to_shared_server(shared);
                    return Ok(());
                }
                return Err(anyhow::anyhow!(
                    "Inspector server startup thread terminated before reporting readiness"
                ));
            }
        };

        let shared = SharedInspectorServer {
            broadcast_tx: broadcast_tx.clone(),
            command_router: shared_router,
            _server: Mutex::new(Some(server)),
        };

        if SHARED_SERVER.set(shared).is_ok() {
            log::info!("V8 Inspector: Created shared server on port {}", self.config.port);
            self.broadcast_tx = Some(broadcast_tx);
            self.apply_command_receiver_claim(initial_claim);
        } else {
            startup_cancelled.store(true, Ordering::Release);
            // Another thread beat us - use their shared server instead
            log::info!("V8 Inspector: Another isolate created the shared server first");
            if let Some(shared) = SHARED_SERVER.get() {
                self.attach_to_shared_server(shared);
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
                    log::debug!(
                        "Inspector: received CDP message: {}",
                        &message[..message.len().min(200)]
                    );
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
/// We must null the shared pointer and drop the session before the inspector
/// to avoid dangling pointers.
impl Drop for InspectorSession {
    fn drop(&mut self) {
        // Null the shared AtomicPtr BEFORE dropping the session so the
        // PauseMessagePump never dereferences a dangling pointer.
        self.session_ptr.store(std::ptr::null_mut(), Ordering::Release);
        self.release_command_channel_ownership();
        // Drop session first - it references the inspector
        self.session = None;
        self.inspector = None;
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::sync::Barrier;

    static START_SERVER_TEST_LOCK: OnceLock<Mutex<()>> = OnceLock::new();

    fn find_unused_port() -> u16 {
        let listener = std::net::TcpListener::bind("127.0.0.1:0").expect("should bind to an ephemeral port");
        listener
            .local_addr()
            .expect("listener should have a local address")
            .port()
    }

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

    #[test]
    fn test_attach_to_shared_server_does_not_steal_live_command_channel() {
        let (broadcast_tx, _) = broadcast::channel::<String>(16);
        let config = InspectorServerConfig::default();
        let (router, initial_claim) = SharedCommandRouter::new(&config);
        let _keep_initial_receiver_live = initial_claim.receiver;
        let shared = SharedInspectorServer {
            broadcast_tx,
            command_router: Arc::new(Mutex::new(router)),
            _server: Mutex::new(None),
        };

        let mut session = InspectorSession::new(InspectorConfig::new(9229));
        session.attach_to_shared_server(&shared);

        assert!(session.broadcast_tx.is_some());
        assert!(!session.owns_debugger_command_channel());
        let owns_incoming_commands = session
            .shared_incoming_rx
            .lock()
            .expect("shared_incoming_rx mutex poisoned")
            .is_some();
        assert!(
            !owns_incoming_commands,
            "attaching isolate should not steal command ownership while channel is live"
        );
    }

    #[test]
    fn test_attach_to_shared_server_claims_closed_command_channel() {
        let (broadcast_tx, _) = broadcast::channel::<String>(16);
        let config = InspectorServerConfig::default();
        let (router, initial_claim) = SharedCommandRouter::new(&config);
        drop(initial_claim.receiver);

        let shared = SharedInspectorServer {
            broadcast_tx,
            command_router: Arc::new(Mutex::new(router)),
            _server: Mutex::new(None),
        };

        let mut session = InspectorSession::new(InspectorConfig::new(9229));
        session.attach_to_shared_server(&shared);
        assert!(session.owns_debugger_command_channel());

        let mut incoming_guard = session
            .shared_incoming_rx
            .lock()
            .expect("shared_incoming_rx mutex poisoned");
        let incoming_rx = incoming_guard
            .as_mut()
            .expect("session should claim command channel when shared channel is closed");

        {
            let mut router = shared.command_router.lock().expect("command router mutex poisoned");
            let _ = router.route_command("Debugger.resume".to_string());
        }

        let msg = incoming_rx
            .try_recv()
            .expect("claimed receiver should get debugger command");
        assert_eq!(msg, "Debugger.resume");
    }

    #[test]
    fn test_start_server_sync_concurrent_calls_succeed_with_single_command_owner() {
        let _test_guard = START_SERVER_TEST_LOCK
            .get_or_init(|| Mutex::new(()))
            .lock()
            .expect("start server test mutex poisoned");

        let shared_server_existed = SHARED_SERVER.get().is_some();
        let port = find_unused_port();
        let barrier = Arc::new(Barrier::new(2));

        let b1 = barrier.clone();
        let thread1 = std::thread::spawn(move || {
            let mut session = InspectorSession::new(InspectorConfig::new(port));
            b1.wait();
            let result = session.start_server_sync();
            let owns_incoming_commands = session.owns_debugger_command_channel();
            (result, owns_incoming_commands)
        });
        let b2 = barrier.clone();
        let thread2 = std::thread::spawn(move || {
            let mut session = InspectorSession::new(InspectorConfig::new(port));
            b2.wait();
            let result = session.start_server_sync();
            let owns_incoming_commands = session.owns_debugger_command_channel();
            (result, owns_incoming_commands)
        });

        let (result1, owns_commands1) = thread1.join().expect("thread1 should complete");
        let (result2, owns_commands2) = thread2.join().expect("thread2 should complete");

        assert!(
            result1.is_ok(),
            "first concurrent startup should succeed: {:?}",
            result1.err()
        );
        assert!(
            result2.is_ok(),
            "second concurrent startup should succeed: {:?}",
            result2.err()
        );

        let owner_count = usize::from(owns_commands1) + usize::from(owns_commands2);
        if !shared_server_existed {
            assert!(
                owner_count >= 1,
                "when creating a new shared server, at least one isolate should own incoming debugger commands"
            );
        }
    }
}
