//! WebSocket server for V8 Inspector connections.
//!
//! This module provides the `InspectorServer` which:
//!
//! - Listens for WebSocket connections from debuggers
//! - Provides the `/json/list` HTTP endpoint for debugger discovery
//! - Routes CDP messages between debuggers and the V8 inspector

use anyhow::{Context, Result};
use futures_util::{SinkExt, StreamExt};
use serde::{Deserialize, Serialize};
use std::net::SocketAddr;
use std::sync::{Arc, Mutex};
use tokio::net::{TcpListener, TcpStream};
use tokio::sync::{broadcast, mpsc};
use tokio_tungstenite::{accept_async, tungstenite::Message};

/// Configuration for the inspector server.
#[derive(Debug, Clone)]
pub struct InspectorServerConfig {
    /// Host to bind to.
    pub host: String,
    /// Port to listen on.
    pub port: u16,
}

impl Default for InspectorServerConfig {
    fn default() -> Self {
        Self {
            host: "127.0.0.1".to_string(),
            port: 9229,
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
    /// Shutdown signal.
    shutdown_tx: Option<mpsc::Sender<()>>,
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

    /// Get target information for the `/json/list` endpoint.
    pub fn get_targets(&self) -> Vec<InspectorTarget> {
        let ws_url = self.websocket_url();
        vec![InspectorTarget {
            description: "SpacetimeDB TypeScript Module".to_string(),
            devtools_frontend_url: format!(
                "devtools://devtools/bundled/js_app.html?experiments=true&v8only=true&ws={}",
                ws_url.strip_prefix("ws://").unwrap_or(&ws_url)
            ),
            id: "spacetimedb-module".to_string(),
            title: "SpacetimeDB Module".to_string(),
            target_type: "node".to_string(),
            url: "file://".to_string(),
            web_socket_debugger_url: ws_url,
        }]
    }

    /// Start the inspector server.
    ///
    /// Returns:
    /// - broadcast sender for CDP messages TO connected debuggers
    /// - shared sender for CDP messages FROM debuggers (swappable via Arc<Mutex<>>)
    /// - initial receiver for CDP messages FROM debuggers
    pub async fn start(
        &mut self,
    ) -> Result<(broadcast::Sender<String>, Arc<Mutex<mpsc::UnboundedSender<String>>>, mpsc::UnboundedReceiver<String>)> {
        let addr = format!("{}:{}", self.config.host, self.config.port);
        let listener = TcpListener::bind(&addr)
            .await
            .with_context(|| format!("Failed to bind inspector server to {}", addr))?;

        log::info!("V8 Inspector listening on {}", addr);
        log::info!("  WebSocket: {}", self.websocket_url());
        log::info!("  Discovery: {}", self.json_list_url());

        let (shutdown_tx, mut shutdown_rx) = mpsc::channel::<()>(1);
        self.shutdown_tx = Some(shutdown_tx);

        // Channel for messages FROM debuggers (to V8)
        // The sender is wrapped in Arc<Mutex<>> so it can be swapped when V8 isolates are replaced
        let (from_debugger_tx, from_debugger_rx) = mpsc::unbounded_channel::<String>();
        let shared_from_debugger_tx = Arc::new(Mutex::new(from_debugger_tx));

        let broadcast_tx = self.broadcast_tx.clone();
        let config = self.config.clone();
        let shared_tx_for_server = shared_from_debugger_tx.clone();

        // Spawn the server task
        tokio::spawn(async move {
            loop {
                tokio::select! {
                    Ok((stream, addr)) = listener.accept() => {
                        log::info!("Inspector connection from {}", addr);

                        let broadcast_tx = broadcast_tx.clone();
                        let shared_tx = shared_tx_for_server.clone();
                        let config = config.clone();

                        tokio::spawn(async move {
                            if let Err(e) = handle_connection(
                                stream,
                                addr,
                                broadcast_tx,
                                shared_tx,
                                &config,
                            ).await {
                                log::error!("Inspector connection error: {}", e);
                            }
                        });
                    }
                    _ = shutdown_rx.recv() => {
                        log::info!("Inspector server shutting down");
                        break;
                    }
                }
            }
        });

        Ok((self.broadcast_tx.clone(), shared_from_debugger_tx, from_debugger_rx))
    }

    /// Shutdown the inspector server.
    pub async fn shutdown(&mut self) {
        if let Some(tx) = self.shutdown_tx.take() {
            let _ = tx.send(()).await;
        }
    }

    /// Broadcast a message to all connected debuggers.
    pub fn broadcast(&self, message: String) {
        let _ = self.broadcast_tx.send(message);
    }
}

/// Handle a single WebSocket connection.
async fn handle_connection(
    stream: TcpStream,
    addr: SocketAddr,
    broadcast_tx: broadcast::Sender<String>,
    shared_from_debugger_tx: Arc<Mutex<mpsc::UnboundedSender<String>>>,
    config: &InspectorServerConfig,
) -> Result<()> {
    // Peek at the first few bytes to determine if this is HTTP or WebSocket
    let mut peek_buf = [0u8; 4];
    stream.peek(&mut peek_buf).await?;

    // Check if this looks like an HTTP request
    if &peek_buf == b"GET " {
        // Read the full request to check the path
        let mut buf = vec![0u8; 1024];
        let n = stream.peek(&mut buf).await?;
        let request = String::from_utf8_lossy(&buf[..n]);

        if request.contains("/json") || request.contains("/json/list") {
            // Handle HTTP request for /json/list
            return handle_json_list(stream, config).await;
        }

        // Otherwise, treat as WebSocket upgrade
    }

    // Accept WebSocket connection
    let ws_stream = accept_async(stream)
        .await
        .context("Failed to accept WebSocket connection")?;

    log::debug!("WebSocket connection established with {}", addr);

    let (mut ws_sink, mut ws_stream) = ws_stream.split();

    // Subscribe to broadcast messages
    let mut broadcast_rx = broadcast_tx.subscribe();

    loop {
        tokio::select! {
            // Message from debugger
            msg = ws_stream.next() => {
                match msg {
                    Some(Ok(Message::Text(text))) => {
                        let text_str = text.to_string();
                        log::debug!("CDP from debugger: {}", &text_str[..text_str.len().min(200)]);
                        // Forward to V8 using the shared (swappable) sender
                        let send_result = {
                            let guard = shared_from_debugger_tx.lock().unwrap();
                            guard.send(text_str)
                        };
                        if let Err(e) = send_result {
                            log::error!("Failed to forward CDP message to V8: {}", e);
                        }
                    }
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
                if let Ok(text) = msg {
                    log::trace!("CDP to debugger: {}", text);
                    if let Err(e) = ws_sink.send(Message::Text(text.into())).await {
                        log::error!("Failed to send to debugger: {}", e);
                        break;
                    }
                }
            }
        }
    }

    Ok(())
}

/// Handle HTTP request for /json/list.
async fn handle_json_list(stream: TcpStream, config: &InspectorServerConfig) -> Result<()> {
    use tokio::io::{AsyncReadExt, AsyncWriteExt};

    let mut stream = stream;

    // Read the HTTP request (we already peeked, now consume)
    let mut buf = vec![0u8; 1024];
    let _ = stream.read(&mut buf).await?;

    // Build the response
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
    let response = format!(
        "HTTP/1.1 200 OK\r\n\
         Content-Type: application/json\r\n\
         Content-Length: {}\r\n\
         Connection: close\r\n\
         \r\n\
         {}",
        body.len(),
        body
    );

    stream.write_all(response.as_bytes()).await?;
    stream.flush().await?;

    Ok(())
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
        };
        let server = InspectorServer::new(config);

        assert_eq!(server.websocket_url(), "ws://127.0.0.1:9229");
        assert_eq!(server.json_list_url(), "http://127.0.0.1:9229/json/list");
    }
}
