//! V8 Inspector Client implementation.
//!
//! This module provides the `InspectorClient` which implements the V8
//! inspector client interface for SpacetimeDB.

use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::{Arc, Mutex};
use tokio::sync::{broadcast, mpsc};
use v8::inspector::{
    ChannelImpl, StringBuffer, StringView, V8InspectorClientImpl, V8InspectorSession, V8StackTrace,
};

/// Configuration for the inspector client.
#[derive(Debug, Clone)]
pub struct InspectorClientConfig {
    /// Whether to break on the first statement.
    pub break_on_start: bool,
}

impl Default for InspectorClientConfig {
    fn default() -> Self {
        Self {
            break_on_start: false,
        }
    }
}

/// Shared state for message processing during pause.
/// This allows the client to dispatch CDP messages while V8 is paused.
pub struct PauseMessagePump {
    /// Receiver for incoming CDP messages from the debugger (shared with session).
    incoming_rx: Arc<Mutex<Option<mpsc::UnboundedReceiver<String>>>>,
    /// Reference to the V8 inspector session for dispatching messages.
    /// We use a raw pointer because the session lifetime is managed by InspectorSession.
    /// Safety: This is only accessed from the V8 thread during run_message_loop_on_pause.
    session_ptr: *const V8InspectorSession,
}

// Safety: PauseMessagePump is only used from the V8 thread
unsafe impl Send for PauseMessagePump {}
unsafe impl Sync for PauseMessagePump {}

impl PauseMessagePump {
    /// Create a new pause message pump with a shared receiver.
    pub fn new(incoming_rx: Arc<Mutex<Option<mpsc::UnboundedReceiver<String>>>>) -> Self {
        Self {
            incoming_rx,
            session_ptr: std::ptr::null(),
        }
    }

    /// Set the session pointer. Must be called before using process_messages.
    /// Safety: The session must outlive the pump.
    pub unsafe fn set_session(&mut self, session: &V8InspectorSession) {
        self.session_ptr = session as *const V8InspectorSession;
    }

    /// Process any pending CDP messages by dispatching them to V8.
    pub fn process_messages(&mut self) {
        if self.session_ptr.is_null() {
            log::trace!("PauseMessagePump: session_ptr is null, skipping");
            return;
        }

        // Try to lock the receiver and process messages
        if let Ok(mut guard) = self.incoming_rx.try_lock() {
            if let Some(ref mut rx) = *guard {
                while let Ok(message) = rx.try_recv() {
                    log::debug!("PauseMessagePump: dispatching CDP message: {}", &message[..message.len().min(200)]);
                    let message_view = StringView::from(message.as_bytes());
                    // Safety: We're on the V8 thread and the session is valid during pause
                    unsafe {
                        (*self.session_ptr).dispatch_protocol_message(message_view);
                    }
                    log::debug!("PauseMessagePump: dispatch complete");
                }
            } else {
                log::trace!("PauseMessagePump: receiver is None");
            }
        } else {
            log::trace!("PauseMessagePump: could not lock receiver");
        }
    }
}

/// The V8 Inspector Client implementation for SpacetimeDB.
///
/// This struct implements `V8InspectorClientImpl` and handles the core
/// debugging functionality:
///
/// - `run_message_loop_on_pause`: Blocks reducer execution while paused
/// - `quit_message_loop_on_pause`: Resumes execution when debugger continues
/// - `console_api_message`: Routes console.log/warn/error to the debugger
pub struct SpacetimeInspectorClient {
    /// Signal to block execution while debugger is paused.
    paused: AtomicBool,

    /// Signal to quit the message loop.
    should_quit: AtomicBool,

    /// Broadcast sender for outgoing CDP messages to connected debuggers.
    message_tx: broadcast::Sender<String>,

    /// Whether to break on the first statement.
    break_on_start: bool,

    /// Message pump for processing CDP messages during pause.
    pause_pump: Arc<Mutex<Option<PauseMessagePump>>>,
}

impl SpacetimeInspectorClient {
    /// Create a new inspector client.
    pub fn new(
        config: InspectorClientConfig,
        message_tx: broadcast::Sender<String>,
    ) -> Self {
        Self {
            paused: AtomicBool::new(false),
            should_quit: AtomicBool::new(false),
            message_tx,
            break_on_start: config.break_on_start,
            pause_pump: Arc::new(Mutex::new(None)),
        }
    }

    /// Set up the pause message pump with the incoming receiver.
    /// Must be called after the session is connected.
    pub fn set_pause_pump(&self, pump: PauseMessagePump) {
        if let Ok(mut guard) = self.pause_pump.lock() {
            *guard = Some(pump);
        }
    }

    /// Get a reference to the pause pump for setting the session.
    pub fn pause_pump(&self) -> Arc<Mutex<Option<PauseMessagePump>>> {
        self.pause_pump.clone()
    }

    /// Check if execution should break on start.
    pub fn should_break_on_start(&self) -> bool {
        self.break_on_start
    }

    /// Check if currently paused.
    pub fn is_paused(&self) -> bool {
        self.paused.load(Ordering::SeqCst)
    }

    /// Signal to quit the message loop (resume execution).
    pub fn signal_quit(&self) {
        self.should_quit.store(true, Ordering::SeqCst);
    }
}

impl V8InspectorClientImpl for SpacetimeInspectorClient {
    /// Called by V8 when execution is paused (e.g., at a breakpoint).
    ///
    /// This method blocks until `quit_message_loop_on_pause` is called,
    /// which happens when the debugger sends a "continue" command.
    fn run_message_loop_on_pause(&self, _context_group_id: i32) {
        log::debug!("V8 Inspector: Execution paused, entering message loop");
        self.paused.store(true, Ordering::SeqCst);
        self.should_quit.store(false, Ordering::SeqCst);

        // Process CDP messages while paused so debugger commands (resume, etc.) work
        while !self.should_quit.load(Ordering::SeqCst) {
            // Try to process any pending messages
            if let Ok(mut guard) = self.pause_pump.lock() {
                if let Some(ref mut pump) = *guard {
                    pump.process_messages();
                }
            }
            std::thread::sleep(std::time::Duration::from_millis(10));
        }

        self.paused.store(false, Ordering::SeqCst);
        log::debug!("V8 Inspector: Resuming execution");
    }

    /// Called by V8 when execution should resume.
    fn quit_message_loop_on_pause(&self) {
        log::debug!("V8 Inspector: Quit message loop requested");
        self.should_quit.store(true, Ordering::SeqCst);
    }

    /// Called when waiting for debugger connection (with --inspect-brk).
    fn run_if_waiting_for_debugger(&self, _context_group_id: i32) {
        if self.break_on_start {
            log::info!("V8 Inspector: Waiting for debugger to connect...");
            // This would be called if we want to wait before first execution
        }
    }

    /// Called when console.log/warn/error is invoked in the module.
    fn console_api_message(
        &self,
        _context_group_id: i32,
        level: i32,
        message: &StringView,
        url: &StringView,
        line_number: u32,
        column_number: u32,
        _stack_trace: &mut V8StackTrace,
    ) {
        // Convert level to string
        let level_str = match level {
            0 => "log",
            1 => "debug",
            2 => "info",
            3 => "error",
            4 => "warning",
            _ => "log",
        };

        // Route to SpacetimeDB's logging system
        let msg = message.to_string();
        let url_str = url.to_string();

        log::debug!(
            "[{}:{}:{}] {}: {}",
            url_str,
            line_number,
            column_number,
            level_str,
            msg
        );

        // Also send to connected debuggers via CDP Runtime.consoleAPICalled
        let cdp_message = serde_json::json!({
            "method": "Runtime.consoleAPICalled",
            "params": {
                "type": level_str,
                "args": [{
                    "type": "string",
                    "value": msg
                }],
                "executionContextId": 1,
                "timestamp": std::time::SystemTime::now()
                    .duration_since(std::time::UNIX_EPOCH)
                    .map(|d| d.as_secs_f64())
                    .unwrap_or(0.0),
                "stackTrace": {
                    "callFrames": [{
                        "functionName": "",
                        "scriptId": "0",
                        "url": url_str,
                        "lineNumber": line_number,
                        "columnNumber": column_number
                    }]
                }
            }
        });

        if let Ok(json) = serde_json::to_string(&cdp_message) {
            let _ = self.message_tx.send(json);
        }
    }
}

/// Channel implementation for routing CDP messages.
///
/// This is the "pipe" between V8's inspector and the WebSocket server.
pub struct SpacetimeInspectorChannel {
    message_tx: broadcast::Sender<String>,
}

impl SpacetimeInspectorChannel {
    /// Create a new channel with the given broadcast sender.
    pub fn new(message_tx: broadcast::Sender<String>) -> Self {
        Self { message_tx }
    }
}

impl ChannelImpl for SpacetimeInspectorChannel {
    /// Called by V8 to send a response to a CDP request.
    fn send_response(&self, call_id: i32, message: v8::UniquePtr<StringBuffer>) {
        if let Some(msg) = message.as_ref() {
            let response = msg.string().to_string();
            log::trace!("CDP Response [{}]: {}", call_id, response);
            let _ = self.message_tx.send(response);
        }
    }

    /// Called by V8 to send a CDP notification (e.g., Debugger.paused).
    fn send_notification(&self, message: v8::UniquePtr<StringBuffer>) {
        if let Some(msg) = message.as_ref() {
            let notification = msg.string().to_string();
            log::trace!("CDP Notification: {}", notification);
            let _ = self.message_tx.send(notification);
        }
    }

    /// Called by V8 when notifications should be flushed.
    fn flush_protocol_notifications(&self) {
        // Nothing to do - we send immediately
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_inspector_client_creation() {
        let (tx, _rx) = broadcast::channel(16);
        let config = InspectorClientConfig::default();
        let client = SpacetimeInspectorClient::new(config, tx);
        assert!(!client.is_paused());
        assert!(!client.should_break_on_start());
    }

    #[test]
    fn test_inspector_client_break_on_start() {
        let (tx, _rx) = broadcast::channel(16);
        let config = InspectorClientConfig {
            break_on_start: true,
        };
        let client = SpacetimeInspectorClient::new(config, tx);
        assert!(client.should_break_on_start());
    }
}
