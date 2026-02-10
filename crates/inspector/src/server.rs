//! WebSocket server for V8 Inspector connections.
//!
//! This module provides the `InspectorServer` which:
//!
//! - Listens for WebSocket connections from debuggers
//! - Provides the `/json/list` HTTP endpoint for debugger discovery
//! - Routes CDP messages between debuggers and the V8 inspector

use crate::CommandQueueOverflowPolicy;
use anyhow::{Context, Result};
use futures_util::{SinkExt, StreamExt};
use serde::{Deserialize, Serialize};
use std::collections::VecDeque;
use std::net::SocketAddr;
use std::sync::atomic::{AtomicUsize, Ordering};
use std::sync::{Arc, Mutex};
use std::time::{Duration, Instant};
use tokio::net::{TcpListener, TcpStream};
use tokio::sync::{broadcast, mpsc};
use tokio_tungstenite::{accept_async, tungstenite::Message};

const OVERFLOW_WARN_INTERVAL: Duration = Duration::from_secs(5);
const NO_OWNER_WARN_INTERVAL: Duration = Duration::from_secs(5);
const PING_INTERVAL: Duration = Duration::from_secs(30);

static ACTIVE_DEBUGGER_CONNECTIONS: AtomicUsize = AtomicUsize::new(0);

/// Configuration for the inspector server.
#[derive(Debug, Clone)]
pub struct InspectorServerConfig {
    /// Host to bind to.
    pub host: String,
    /// Port to listen on.
    pub port: u16,
    /// Maximum number of inbound debugger commands to queue while no isolate owns the receiver.
    pub max_pending_debugger_commands: usize,
    /// Maximum total bytes of queued inbound debugger commands.
    pub max_pending_command_bytes: usize,
    /// Overflow behavior when the pending command queue is at capacity.
    pub command_queue_overflow_policy: CommandQueueOverflowPolicy,
}

impl Default for InspectorServerConfig {
    fn default() -> Self {
        Self {
            host: "127.0.0.1".to_string(),
            port: 9229,
            max_pending_debugger_commands: 256,
            max_pending_command_bytes: 1024 * 1024,
            command_queue_overflow_policy: CommandQueueOverflowPolicy::DropOldestWithWarn,
        }
    }
}

/// Response format for `/json/list` endpoint (Chrome DevTools Protocol).
#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct InspectorTarget {
    /// Description of the target.
    pub description: String,
    /// URL that DevTools can use to attach.
    pub devtools_frontend_url: String,
    /// Unique ID for this target.
    pub id: String,
    /// Title of the target.
    pub title: String,
    /// Type of target (always "node" for compatibility).
    #[serde(rename = "type")]
    pub target_type: String,
    /// URL being debugged.
    pub url: String,
    /// WebSocket URL for debugger connection.
    pub web_socket_debugger_url: String,
}

/// The WebSocket server for inspector connections.
pub struct InspectorServer {
    config: InspectorServerConfig,
    /// Broadcast channel for sending messages to all connected sessions.
    broadcast_tx: broadcast::Sender<String>,
    /// Shutdown signal for the listener task.
    shutdown_tx: Option<mpsc::Sender<()>>,
}

/// Outcome for routing inbound debugger commands.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub(crate) enum CommandRouteOutcome {
    Delivered,
    QueuedNoOwner,
    QueuedClosedOwner,
    DroppedOverflow,
}

/// Snapshot of command routing counters.
#[derive(Debug, Clone, Default)]
pub(crate) struct CommandRouterStats {
    pub routed_total: u64,
    pub enqueued_total: u64,
    pub dropped_total: u64,
}

/// Receiver ownership claim for inbound debugger commands.
pub(crate) struct CommandReceiverClaim {
    pub epoch: u64,
    pub receiver: mpsc::UnboundedReceiver<String>,
    pub drained_count: usize,
}

/// Shared router state for debugger -> isolate command delivery.
pub(crate) struct SharedCommandRouter {
    sender: mpsc::UnboundedSender<String>,
    owner_epoch: Option<u64>,
    next_epoch: u64,
    pending: VecDeque<String>,
    pending_bytes: usize,
    max_pending_commands: usize,
    max_pending_command_bytes: usize,
    overflow_policy: CommandQueueOverflowPolicy,
    stats: CommandRouterStats,
    last_overflow_warn: Option<Instant>,
    last_no_owner_warn: Option<Instant>,
}

impl SharedCommandRouter {
    pub(crate) fn new(config: &InspectorServerConfig) -> (Self, CommandReceiverClaim) {
        let (sender, receiver) = mpsc::unbounded_channel::<String>();
        let epoch = 1;

        (
            Self {
                sender,
                owner_epoch: Some(epoch),
                next_epoch: epoch + 1,
                pending: VecDeque::new(),
                pending_bytes: 0,
                max_pending_commands: config.max_pending_debugger_commands,
                max_pending_command_bytes: config.max_pending_command_bytes,
                overflow_policy: config.command_queue_overflow_policy,
                stats: CommandRouterStats::default(),
                last_overflow_warn: None,
                last_no_owner_warn: None,
            },
            CommandReceiverClaim {
                epoch,
                receiver,
                drained_count: 0,
            },
        )
    }

    pub(crate) fn route_command(&mut self, command: String) -> CommandRouteOutcome {
        if self.owner_epoch.is_some() && !self.sender.is_closed() {
            return match self.sender.send(command) {
                Ok(()) => {
                    self.stats.routed_total += 1;
                    CommandRouteOutcome::Delivered
                }
                Err(e) => {
                    self.owner_epoch = None;
                    self.queue_command(e.0, true)
                }
            };
        }

        self.queue_command(command, false)
    }

    pub(crate) fn claim_receiver_if_needed(&mut self) -> Option<CommandReceiverClaim> {
        if self.owner_epoch.is_some() && !self.sender.is_closed() {
            return None;
        }

        let (new_sender, new_receiver) = mpsc::unbounded_channel::<String>();
        let epoch = self.next_epoch;
        self.next_epoch += 1;
        self.owner_epoch = Some(epoch);
        self.sender = new_sender;

        let mut drained_count = 0usize;
        while let Some(command) = self.pending.pop_front() {
            self.pending_bytes = self.pending_bytes.saturating_sub(command.len());
            if self.sender.send(command).is_ok() {
                drained_count += 1;
                self.stats.routed_total += 1;
            } else {
                break;
            }
        }

        Some(CommandReceiverClaim {
            epoch,
            receiver: new_receiver,
            drained_count,
        })
    }

    pub(crate) fn release_if_owner(&mut self, epoch: u64) -> bool {
        if self.owner_epoch == Some(epoch) {
            self.owner_epoch = None;
            self.sender = Self::closed_sender();
            return true;
        }
        false
    }

    pub(crate) fn stats(&self) -> CommandRouterStats {
        self.stats.clone()
    }

    fn queue_command(&mut self, command: String, closed_owner: bool) -> CommandRouteOutcome {
        let cmd_bytes = command.len();
        if self.max_pending_commands == 0 || self.max_pending_command_bytes == 0 {
            self.stats.dropped_total += 1;
            self.warn_overflow("queue disabled");
            return CommandRouteOutcome::DroppedOverflow;
        }

        if cmd_bytes > self.max_pending_command_bytes {
            self.stats.dropped_total += 1;
            self.warn_overflow("single command exceeds byte budget");
            return CommandRouteOutcome::DroppedOverflow;
        }

        match self.overflow_policy {
            CommandQueueOverflowPolicy::DropOldestWithWarn => {
                let mut dropped_oldest = 0usize;
                while self.pending.len() >= self.max_pending_commands
                    || self.pending_bytes + cmd_bytes > self.max_pending_command_bytes
                {
                    let Some(oldest) = self.pending.pop_front() else {
                        break;
                    };
                    self.pending_bytes = self.pending_bytes.saturating_sub(oldest.len());
                    self.stats.dropped_total += 1;
                    dropped_oldest += 1;
                }
                if dropped_oldest > 0 {
                    self.warn_overflow("dropped oldest queued commands");
                }
                if self.pending.len() >= self.max_pending_commands
                    || self.pending_bytes + cmd_bytes > self.max_pending_command_bytes
                {
                    self.stats.dropped_total += 1;
                    self.warn_overflow("unable to make room for queued command");
                    return CommandRouteOutcome::DroppedOverflow;
                }
                self.pending.push_back(command);
                self.pending_bytes += cmd_bytes;
                self.stats.enqueued_total += 1;
            }
            CommandQueueOverflowPolicy::DropNewestWithWarn => {
                if self.pending.len() >= self.max_pending_commands
                    || self.pending_bytes + cmd_bytes > self.max_pending_command_bytes
                {
                    self.stats.dropped_total += 1;
                    self.warn_overflow("dropping newest command due to full queue");
                    return CommandRouteOutcome::DroppedOverflow;
                }
                self.pending.push_back(command);
                self.pending_bytes += cmd_bytes;
                self.stats.enqueued_total += 1;
            }
        }

        if closed_owner {
            self.warn_no_owner("owner channel closed; command queued");
            CommandRouteOutcome::QueuedClosedOwner
        } else {
            self.warn_no_owner("no active owner; command queued");
            CommandRouteOutcome::QueuedNoOwner
        }
    }

    fn warn_overflow(&mut self, reason: &str) {
        let now = Instant::now();
        if self
            .last_overflow_warn
            .is_none_or(|last| now.duration_since(last) >= OVERFLOW_WARN_INTERVAL)
        {
            log::warn!(
                "Inspector command queue overflow: reason={reason}, pending={}, pending_bytes={}, dropped_total={}",
                self.pending.len(),
                self.pending_bytes,
                self.stats.dropped_total
            );
            self.last_overflow_warn = Some(now);
        }
    }

    fn warn_no_owner(&mut self, reason: &str) {
        let now = Instant::now();
        if self
            .last_no_owner_warn
            .is_none_or(|last| now.duration_since(last) >= NO_OWNER_WARN_INTERVAL)
        {
            log::warn!(
                "Inspector command queued: reason={reason}, pending={}, pending_bytes={}, owner_epoch={:?}",
                self.pending.len(),
                self.pending_bytes,
                self.owner_epoch
            );
            self.last_no_owner_warn = Some(now);
        }
    }

    fn closed_sender() -> mpsc::UnboundedSender<String> {
        let (sender, receiver) = mpsc::unbounded_channel::<String>();
        drop(receiver);
        sender
    }
}

impl InspectorServer {
    /// Create a new inspector server.
    pub fn new(config: InspectorServerConfig) -> Self {
        let (broadcast_tx, _) = broadcast::channel(1024);

        Self {
            config,
            broadcast_tx,
            shutdown_tx: None,
        }
    }

    /// Get the WebSocket URL for debugger connections.
    pub fn websocket_url(&self) -> String {
        format!("ws://{}:{}", self.config.host, self.config.port)
    }

    /// Get the JSON list URL for debugger discovery.
    pub fn json_list_url(&self) -> String {
        format!("http://{}:{}/json/list", self.config.host, self.config.port)
    }

    /// Start the inspector server.
    ///
    /// Returns:
    /// - broadcast sender for CDP messages TO connected debuggers
    /// - shared router for CDP messages FROM debuggers
    /// - initial ownership claim for CDP messages FROM debuggers
    pub(crate) async fn start(
        &mut self,
    ) -> Result<(
        broadcast::Sender<String>,
        Arc<Mutex<SharedCommandRouter>>,
        CommandReceiverClaim,
    )> {
        let addr = format!("{}:{}", self.config.host, self.config.port);
        let listener = TcpListener::bind(&addr)
            .await
            .with_context(|| format!("Failed to bind inspector server to {}", addr))?;

        log::info!("V8 Inspector listening on {}", addr);
        log::info!("  WebSocket: {}", self.websocket_url());
        log::info!("  Discovery: {}", self.json_list_url());

        let (shutdown_tx, mut shutdown_rx) = mpsc::channel::<()>(1);
        self.shutdown_tx = Some(shutdown_tx);

        let (router, initial_claim) = SharedCommandRouter::new(&self.config);
        let shared_router = Arc::new(Mutex::new(router));

        let broadcast_tx = self.broadcast_tx.clone();
        let config = self.config.clone();
        let shared_router_for_server = shared_router.clone();

        // Spawn the server task
        tokio::spawn(async move {
            loop {
                tokio::select! {
                    accept_result = listener.accept() => {
                        match accept_result {
                            Ok((stream, addr)) => {
                                log::info!("Inspector connection from {}", addr);

                                let broadcast_tx = broadcast_tx.clone();
                                let shared_router = shared_router_for_server.clone();
                                let config = config.clone();

                                tokio::spawn(async move {
                                    if let Err(e) = handle_connection(stream, addr, broadcast_tx, shared_router, &config).await {
                                        log::error!("Inspector connection error: {}", e);
                                    }
                                });
                            }
                            Err(e) => {
                                log::error!("Inspector server accept error: {}", e);
                            }
                        }
                    }
                    _ = shutdown_rx.recv() => {
                        log::info!("Inspector server shutting down");
                        break;
                    }
                }
            }
        });

        Ok((self.broadcast_tx.clone(), shared_router, initial_claim))
    }

    /// Shutdown the inspector server listener.
    pub async fn shutdown(&mut self) {
        if let Some(tx) = self.shutdown_tx.take() {
            let _ = tx.send(()).await;
        }
    }
}

impl Drop for InspectorServer {
    fn drop(&mut self) {
        if let Some(tx) = self.shutdown_tx.take() {
            let _ = tx.try_send(());
        }
    }
}

/// Handle a single WebSocket connection.
async fn handle_connection(
    stream: TcpStream,
    addr: SocketAddr,
    broadcast_tx: broadcast::Sender<String>,
    shared_command_router: Arc<Mutex<SharedCommandRouter>>,
    config: &InspectorServerConfig,
) -> Result<()> {
    // Peek at the first few bytes to determine if this is HTTP or WebSocket
    let mut peek_buf = [0u8; 4];
    stream.peek(&mut peek_buf).await?;

    // Check if this looks like an HTTP request
    if &peek_buf == b"GET " {
        // Read the full request to check the path
        let mut buf = vec![0u8; 2048];
        let n = stream.peek(&mut buf).await?;
        let request = String::from_utf8_lossy(&buf[..n]);
        let request_line_result = parse_http_request_line(&request);

        match request_line_result {
            Ok(path) if path == "/json" || path == "/json/list" => {
                // Handle HTTP request for /json/list.
                return handle_json_list(stream, config).await;
            }
            Ok(_path) if !is_websocket_upgrade(&request) => {
                return handle_http_error(stream, 404, "Not Found").await;
            }
            Ok(_) => {
                // WebSocket upgrade request: continue with the upgrade flow.
            }
            Err(_) => {
                return handle_http_error(stream, 400, "Bad Request").await;
            }
        }
    }

    // Accept WebSocket connection
    let ws_stream = accept_async(stream)
        .await
        .context("Failed to accept WebSocket connection")?;

    log::debug!("WebSocket connection established with {}", addr);

    let (mut ws_sink, mut ws_stream) = ws_stream.split();

    // Subscribe to broadcast messages
    let mut broadcast_rx = broadcast_tx.subscribe();
    let mut ping_interval = tokio::time::interval(PING_INTERVAL);
    ping_interval.set_missed_tick_behavior(tokio::time::MissedTickBehavior::Delay);
    let _connection_guard = ActiveConnectionGuard::new(addr);

    loop {
        tokio::select! {
            _ = ping_interval.tick() => {
                if let Err(e) = ws_sink.send(Message::Ping(Vec::new().into())).await {
                    log::info!("Debugger ping failed for {}: {}", addr, e);
                    break;
                }
            }

            // Message from debugger
            msg = ws_stream.next() => {
                match msg {
                    Some(Ok(Message::Text(text))) => {
                        let text_str = text.to_string();
                        log::debug!("CDP from debugger: {}", &text_str[..text_str.len().min(200)]);
                        let route_outcome = {
                            let mut guard = shared_command_router.lock()
                                .expect("shared command router mutex poisoned");
                            guard.route_command(text_str)
                        };
                        match route_outcome {
                            CommandRouteOutcome::Delivered => {}
                            CommandRouteOutcome::QueuedNoOwner | CommandRouteOutcome::QueuedClosedOwner => {
                                log::debug!("Queued inbound debugger command: {:?}", route_outcome);
                            }
                            CommandRouteOutcome::DroppedOverflow => {
                                log::warn!("Dropped inbound debugger command due to queue overflow");
                            }
                        }
                    }
                    Some(Ok(Message::Ping(payload))) => {
                        if let Err(e) = ws_sink.send(Message::Pong(payload)).await {
                            log::debug!("Failed to send websocket pong: {}", e);
                            break;
                        }
                    }
                    Some(Ok(Message::Pong(_))) => {}
                    Some(Ok(Message::Close(_))) | None => {
                        log::info!("Debugger disconnected from {}", addr);
                        break;
                    }
                    Some(Ok(_)) => {
                        // Ignore other message types
                    }
                    Some(Err(e)) => {
                        log::error!("WebSocket error: {}", e);
                        break;
                    }
                }
            }

            // Message to debugger (from V8)
            msg = broadcast_rx.recv() => {
                match msg {
                    Ok(text) => {
                        log::trace!("CDP to debugger: {}", text);
                        if let Err(e) = ws_sink.send(Message::Text(text.into())).await {
                            log::error!("Failed to send to debugger: {}", e);
                            break;
                        }
                    }
                    Err(broadcast::error::RecvError::Lagged(n)) => {
                        log::warn!("Inspector broadcast lagged, dropped {} messages", n);
                    }
                    Err(broadcast::error::RecvError::Closed) => {
                        log::info!("Inspector broadcast channel closed");
                        break;
                    }
                }
            }
        }
    }

    Ok(())
}

fn parse_http_request_line(request: &str) -> Result<&str> {
    let request_line = request.lines().next().context("missing HTTP request line")?;
    let mut parts = request_line.split_whitespace();
    let method = parts.next().context("missing HTTP method")?;
    let path = parts.next().context("missing HTTP path")?;
    let version = parts.next().context("missing HTTP version")?;

    if method != "GET" {
        anyhow::bail!("unsupported HTTP method: {}", method);
    }
    if !version.starts_with("HTTP/") {
        anyhow::bail!("invalid HTTP version: {}", version);
    }
    Ok(path)
}

fn is_websocket_upgrade(request: &str) -> bool {
    request.lines().any(|line| {
        let line = line.trim();
        let lower = line.to_ascii_lowercase();
        lower.starts_with("upgrade:") && lower.contains("websocket")
    })
}

async fn handle_http_error(stream: TcpStream, status_code: u16, status_text: &str) -> Result<()> {
    use tokio::io::AsyncWriteExt;

    let mut stream = stream;
    let response = build_http_response(status_code, status_text, "text/plain; charset=utf-8", status_text);
    stream.write_all(response.as_bytes()).await?;
    stream.flush().await?;
    Ok(())
}

fn build_http_response(status_code: u16, status_text: &str, content_type: &str, body: &str) -> String {
    format!(
        "HTTP/1.1 {} {}\r\nContent-Type: {}\r\nContent-Length: {}\r\nCache-Control: no-store\r\nConnection: close\r\n\r\n{}",
        status_code,
        status_text,
        content_type,
        body.len(),
        body
    )
}

struct ActiveConnectionGuard {
    addr: SocketAddr,
}

impl ActiveConnectionGuard {
    fn new(addr: SocketAddr) -> Self {
        let active = ACTIVE_DEBUGGER_CONNECTIONS.fetch_add(1, Ordering::SeqCst) + 1;
        log::debug!(
            "Active inspector debugger connections: {} (connected: {})",
            active,
            addr
        );
        Self { addr }
    }
}

impl Drop for ActiveConnectionGuard {
    fn drop(&mut self) {
        let active = ACTIVE_DEBUGGER_CONNECTIONS
            .fetch_sub(1, Ordering::SeqCst)
            .saturating_sub(1);
        log::debug!(
            "Active inspector debugger connections: {} (disconnected: {})",
            active,
            self.addr
        );
    }
}

/// Handle HTTP request for /json/list.
async fn handle_json_list(stream: TcpStream, config: &InspectorServerConfig) -> Result<()> {
    use tokio::io::{AsyncReadExt, AsyncWriteExt};

    let mut stream = stream;

    // Read the HTTP request (we already peeked, now consume)
    let mut buf = vec![0u8; 1024];
    let _ = stream.read(&mut buf).await?;

    let response = build_json_list_response(config)?;

    stream.write_all(response.as_bytes()).await?;
    stream.flush().await?;

    Ok(())
}

fn build_json_list_response(config: &InspectorServerConfig) -> Result<String> {
    let ws_url = format!("ws://{}:{}", config.host, config.port);
    let targets = vec![InspectorTarget {
        description: "SpacetimeDB TypeScript Module".to_string(),
        devtools_frontend_url: format!(
            "devtools://devtools/bundled/js_app.html?experiments=true&v8only=true&ws={}:{}",
            config.host, config.port
        ),
        id: "spacetimedb-module".to_string(),
        title: "SpacetimeDB Module".to_string(),
        target_type: "node".to_string(),
        url: "file://".to_string(),
        web_socket_debugger_url: ws_url,
    }];

    let body = serde_json::to_string(&targets)?;
    Ok(build_http_response(200, "OK", "application/json; charset=utf-8", &body))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_inspector_target_serialization() {
        let target = InspectorTarget {
            description: "Test".to_string(),
            devtools_frontend_url: "devtools://...".to_string(),
            id: "test-id".to_string(),
            title: "Test Target".to_string(),
            target_type: "node".to_string(),
            url: "file://".to_string(),
            web_socket_debugger_url: "ws://localhost:9229".to_string(),
        };

        let json = serde_json::to_string(&target).unwrap();
        assert!(json.contains("webSocketDebuggerUrl"));
        assert!(json.contains("devtoolsFrontendUrl"));
    }

    #[test]
    fn test_server_urls() {
        let config = InspectorServerConfig {
            host: "127.0.0.1".to_string(),
            port: 9229,
            ..Default::default()
        };
        let server = InspectorServer::new(config);

        assert_eq!(server.websocket_url(), "ws://127.0.0.1:9229");
        assert_eq!(server.json_list_url(), "http://127.0.0.1:9229/json/list");
    }

    #[test]
    fn test_json_list_response_has_valid_http_format() {
        let config = InspectorServerConfig {
            host: "127.0.0.1".to_string(),
            port: 9229,
            ..Default::default()
        };

        let response = build_json_list_response(&config).expect("response should be generated");
        assert!(response.starts_with("HTTP/1.1 200 OK\r\n"));

        let (headers, body) = response
            .split_once("\r\n\r\n")
            .expect("response should contain a header/body separator");

        for line in headers.split("\r\n").skip(1) {
            assert!(
                !line.starts_with(' ') && !line.starts_with('\t'),
                "header line must not start with folding whitespace: {line:?}"
            );
        }

        let content_length = headers
            .split("\r\n")
            .find_map(|line| line.strip_prefix("Content-Length: "))
            .expect("Content-Length header should be present")
            .parse::<usize>()
            .expect("Content-Length should be numeric");
        assert_eq!(content_length, body.len());

        let parsed: serde_json::Value = serde_json::from_str(body).expect("response body should be valid JSON");
        assert!(parsed.is_array());
    }

    #[test]
    fn test_parse_http_request_line() {
        let request = "GET /json/list HTTP/1.1\r\nHost: localhost\r\n\r\n";
        let path = parse_http_request_line(request).expect("request line should parse");
        assert_eq!(path, "/json/list");
    }

    #[test]
    fn test_parse_http_request_line_rejects_malformed() {
        let malformed = "GET_ONLY\r\nHost: localhost\r\n\r\n";
        assert!(parse_http_request_line(malformed).is_err());
    }

    #[test]
    fn test_websocket_upgrade_detection() {
        let request = "GET / HTTP/1.1\r\nConnection: Upgrade\r\nUpgrade: websocket\r\n\r\n";
        assert!(is_websocket_upgrade(request));
    }

    #[test]
    fn test_command_router_queue_and_claim() {
        let config = InspectorServerConfig {
            max_pending_debugger_commands: 2,
            max_pending_command_bytes: 8,
            ..Default::default()
        };
        let (mut router, _claim1) = SharedCommandRouter::new(&config);
        // Drop current owner.
        router.release_if_owner(1);

        assert_eq!(
            router.route_command("Debugger.enable".to_string()),
            CommandRouteOutcome::DroppedOverflow
        );
        assert_eq!(
            router.route_command("{\"id\":1}".to_string()),
            CommandRouteOutcome::QueuedNoOwner
        );
        assert_eq!(
            router.route_command("{\"id\":2}".to_string()),
            CommandRouteOutcome::QueuedNoOwner
        );
        let claim2 = router
            .claim_receiver_if_needed()
            .expect("router should issue a new receiver claim");
        assert_eq!(claim2.drained_count, 1);
    }
}
