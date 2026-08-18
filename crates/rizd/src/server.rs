use crate::{
    config::data_dir,
    files,
    provider::{AgentProvider, PromptRequest, ProviderRuntimeEvent},
    skills,
    state::{AppState, Outbound, UploadTransfer},
    updater::{self, UpdateChannel},
};
use anyhow::{Context, Result, bail};
use axum::{
    Router,
    extract::{
        State, WebSocketUpgrade,
        ws::{Message, WebSocket},
    },
    http::{HeaderValue, Method},
    response::IntoResponse,
    routing::get,
};
use base64::{Engine, engine::general_purpose::STANDARD};
use futures_util::{SinkExt, StreamExt};
use riz_protocol::{BinaryChannel, Envelope, PROTOCOL_VERSION, decode_binary, encode_binary};
use serde_json::{Value, json};
use std::{
    collections::HashSet,
    path::{Path, PathBuf},
    sync::{Arc, Mutex},
    time::Duration,
};
use tokio::sync::broadcast;
use tower_http::{cors::CorsLayer, trace::TraceLayer};
use uuid::Uuid;

const MAX_INITIAL_EVENT_REPLAY: usize = 50;

pub async fn serve(state: AppState) -> Result<()> {
    let listen = state.config.listen;
    if !listen.ip().is_loopback() {
        tracing::warn!(%listen,"Riz is listening on a non-loopback address without TLS; use a trusted TLS tunnel");
    }
    let app = router(state);
    let listener = tokio::net::TcpListener::bind(listen).await?;
    tracing::info!(%listen,"rizd listening");
    axum::serve(listener, app).await?;
    Ok(())
}

fn router(state: AppState) -> Router {
    let cors = CorsLayer::new()
        .allow_methods([Method::GET])
        .allow_origin(HeaderValue::from_static("*"));
    Router::new()
        .route(
            "/health",
            get(|| async { axum::Json(json!({"ok":true,"protocolVersion":PROTOCOL_VERSION})) }),
        )
        .route("/ws", get(ws_upgrade))
        .layer(cors)
        .layer(TraceLayer::new_for_http())
        .with_state(state)
}

async fn ws_upgrade(ws: WebSocketUpgrade, State(state): State<AppState>) -> impl IntoResponse {
    ws.max_message_size(26 * 1024 * 1024)
        .on_upgrade(move |socket| client(socket, state))
}

async fn client(socket: WebSocket, state: AppState) {
    if let Err(e) = client_inner(socket, state).await {
        tracing::debug!(error=%e,"websocket closed")
    }
}
async fn client_inner(mut socket: WebSocket, state: AppState) -> Result<()> {
    let auth = tokio::time::timeout(Duration::from_secs(5), socket.recv())
        .await
        .context("authentication timeout")?
        .context("socket closed")??;
    let Message::Text(text) = auth else {
        bail!("first frame must be auth JSON")
    };
    let envelope: Envelope = serde_json::from_str(&text)?;
    if envelope.kind != "auth" {
        bail!("first frame must be auth")
    }
    let client_trace_id = envelope.payload["clientTraceId"]
        .as_str()
        .unwrap_or("unavailable");
    tracing::info!(client_trace_id, "websocket authentication received");
    let token = envelope.payload["token"].as_str().unwrap_or_default();
    if !state.config.verify_token(token) {
        tracing::warn!(client_trace_id, "websocket authentication rejected");
        state.auth_limiter.record_failure();
        tokio::time::sleep(state.auth_limiter.delay()).await;
        let failure = Envelope::failure(
            &envelope,
            state.daemon_id(),
            "unauthorized",
            "invalid token",
        );
        socket
            .send(Message::Text(serde_json::to_string(&failure)?.into()))
            .await?;
        bail!("invalid token")
    }
    let last_seq = envelope.payload["lastSeq"].as_i64().unwrap_or(0);
    let detected = state.agy.detect();
    let hello = Envelope::response(
        &envelope,
        state.daemon_id(),
        json!({"kind":"hello","clientTraceId":client_trace_id,"daemon":{"id":state.daemon_id(),"name":state.config.name,"version":updater::current_version()},"protocolVersion":PROTOCOL_VERSION,"providers":[detected]}),
    );
    tracing::info!(client_trace_id, "websocket authentication accepted");
    socket
        .send(Message::Text(serde_json::to_string(&hello)?.into()))
        .await?;
    tracing::info!(client_trace_id, "websocket hello sent");
    let events = state
        .db
        .events_after(last_seq, (MAX_INITIAL_EVENT_REPLAY + 1) as i64)?;
    if events.len() > MAX_INITIAL_EVENT_REPLAY {
        let snapshot = wire_event(
            state.daemon_id(),
            state.db.last_seq()?,
            "snapshot",
            state.db.snapshot()?,
        );
        socket
            .send(Message::Text(serde_json::to_string(&snapshot)?.into()))
            .await?;
    } else {
        for e in events {
            socket
                .send(Message::Text(
                    serde_json::to_string(&wire_event(
                        state.daemon_id(),
                        e.seq,
                        &e.topic,
                        e.payload,
                    ))?
                    .into(),
                ))
                .await?;
        }
    }
    let (mut tx, mut rx) = socket.split();
    let mut pushes = state.outbound.subscribe();
    let mut heartbeat = tokio::time::interval(Duration::from_secs(10));
    heartbeat.set_missed_tick_behavior(tokio::time::MissedTickBehavior::Delay);
    heartbeat.tick().await;
    loop {
        tokio::select! {
            incoming=rx.next()=>{let Some(incoming)=incoming else{break};match incoming?{Message::Text(text)=>{let request=match serde_json::from_str::<Envelope>(&text){Ok(v)=>v,Err(e)=>{tracing::debug!(%e,"invalid envelope");continue}};let response=match dispatch(&state,&request).await{Ok(v)=>Envelope::response(&request,state.daemon_id(),v),Err(e)=>Envelope::failure(&request,state.daemon_id(),"request_failed",e.to_string())};tx.send(Message::Text(serde_json::to_string(&response)?.into())).await?;}Message::Binary(frame)=>handle_binary(&state,&frame)?,Message::Close(_)=>break,Message::Ping(v)=>tx.send(Message::Pong(v)).await?,_=>{}}}
            push=pushes.recv()=>match push{Ok(Outbound::Event(e))=>tx.send(Message::Text(serde_json::to_string(&wire_event(state.daemon_id(),e.seq,&e.topic,e.payload))?.into())).await?,Ok(Outbound::Binary(v))=>tx.send(Message::Binary(v.into())).await?,Err(broadcast::error::RecvError::Lagged(_))=>{let seq=state.db.last_seq()?;tx.send(Message::Text(serde_json::to_string(&wire_event(state.daemon_id(),seq,"snapshot",state.db.snapshot()?))?.into())).await?},Err(_)=>break},
            _=heartbeat.tick()=>tx.send(Message::Ping(Vec::new().into())).await?,
        }
    }
    tracing::info!(client_trace_id, "websocket client disconnected");
    Ok(())
}

async fn dispatch(state: &AppState, request: &Envelope) -> Result<Value> {
    if request.v != PROTOCOL_VERSION {
        bail!("unsupported protocol version")
    };
    let method = request.payload["method"]
        .as_str()
        .context("missing method")?;
    let p = &request.payload["params"];
    match method {
        "system.info" => Ok(json!({
            "home": dirs::home_dir(),
            "platform": std::env::consts::OS,
            "architecture": std::env::consts::ARCH,
            "daemonId": state.daemon_id(),
            "provider": state.agy.detect(),
            "version": updater::current_version(),
            "updateChannel": updater::configured_channel(),
        })),
        "system.ping" => Ok(json!({"pong":true})),
        "daemon.update.status" => Ok(updater::status()),
        "daemon.update.check" => {
            let channel = UpdateChannel::parse(p["channel"].as_str().unwrap_or(
                match updater::configured_channel() {
                    UpdateChannel::Stable => "stable",
                    UpdateChannel::Prerelease => "prerelease",
                },
            ))?;
            Ok(serde_json::to_value(updater::check(channel).await?)?)
        }
        "daemon.update.install" => {
            let channel = UpdateChannel::parse(p["channel"].as_str().unwrap_or(
                match updater::configured_channel() {
                    UpdateChannel::Stable => "stable",
                    UpdateChannel::Prerelease => "prerelease",
                },
            ))?;
            let update = updater::install(channel).await?;
            let restart_scheduled = update.is_available() && updater::schedule_restart()?;
            let mut response = serde_json::to_value(update)?;
            response["restartScheduled"] = json!(restart_scheduled);
            Ok(response)
        }
        "snapshot.get" => state.db.snapshot(),
        "events.get" => Ok(
            json!({"events":state.db.events_after(p["afterSeq"].as_i64().unwrap_or(0),p["limit"].as_i64().unwrap_or(500).clamp(1,1000))?}),
        ),
        "project.list" => Ok(json!({"projects":state.db.projects()?})),
        "project.create" => {
            let paths = p["folders"]
                .as_array()
                .context("missing folders")?
                .iter()
                .map(|folder| {
                    folder
                        .as_str()
                        .map(PathBuf::from)
                        .context("invalid project folder")
                })
                .collect::<Result<Vec<_>>>()?;
            let project = state.db.create_project(p["name"].as_str(), &paths)?;
            state.emit("project.changed", project.clone())?;
            Ok(project)
        }
        "project.rename" => {
            let project = state
                .db
                .rename_project(str_param(p, "projectId")?, p["name"].as_str())?;
            state.emit("project.changed", project.clone())?;
            Ok(project)
        }
        "project.folder.add" => {
            let project = state
                .db
                .add_project_folder(str_param(p, "projectId")?, &files::path_from(p, "path")?)?;
            state.emit("project.changed", project.clone())?;
            Ok(project)
        }
        "project.folder.remove" => {
            let project = state
                .db
                .remove_project_folder(str_param(p, "projectId")?, str_param(p, "folderId")?)?;
            state.emit("project.changed", project.clone())?;
            Ok(project)
        }
        "project.remove" => {
            let id = p["projectId"]
                .as_str()
                .or_else(|| p["id"].as_str())
                .context("missing projectId")?;
            let mode = match str_param(p, "mode")? {
                "detach" | "detach_sessions" => "detach_sessions",
                "delete" | "delete_sessions" => "delete_sessions",
                _ => bail!("invalid project removal mode"),
            };
            let affected_sessions = state.db.sessions(Some(id), true)?;
            for session in &affected_sessions {
                if let Some(session_id) = session["id"].as_str() {
                    state.agy.cancel(session_id).await?;
                }
            }
            let result = state.db.remove_project(id, mode)?;
            state.emit("project.removed", json!({"id":id}))?;
            for session in result["detachedSessions"].as_array().into_iter().flatten() {
                state.emit("session.changed", session.clone())?;
            }
            for session_id in result["deletedSessionIds"].as_array().into_iter().flatten() {
                state.emit("session.removed", json!({"id":session_id}))?;
            }
            Ok(json!({"removed":true,"mode":mode}))
        }
        "session.list" => Ok(
            json!({"sessions":state.db.sessions(p["projectId"].as_str(),p["includeArchived"].as_bool().unwrap_or(false))?}),
        ),
        "session.get" => {
            let id = str_param(p, "id")?;
            let response = json!({"session":state.db.session(id)?,"providerConversations":state.db.provider_conversations(id)?,"turns":state.db.turns(Some(id))?,"messages":state.db.messages(id)?,"structuredEvents":state.db.structured_events(id)?,"attachments":state.db.attachments(id)?,"pendingPermission":state.agy.pending_permission(id),"pendingInput":state.agy.pending_input(id)});
            if !state.db.queued_messages(id)?.is_empty() {
                start_worker(state.clone(), id.to_owned());
            }
            Ok(response)
        }
        "session.create" => {
            let project_id = p["projectId"].as_str();
            let s = state.db.create_session_with_details(
                project_id,
                p["title"].as_str(),
                p["provider"].as_str().unwrap_or("agy"),
                None,
                p["permissionMode"].as_str().unwrap_or("workspace"),
                p["model"].as_str(),
                &data_dir().join("sessions"),
            )?;
            state.emit("session.changed", s.clone())?;
            Ok(s)
        }
        "session.move" => {
            let session = state
                .db
                .move_session(str_param(p, "sessionId")?, p["projectId"].as_str())?;
            state.emit("session.changed", session.clone())?;
            Ok(session)
        }
        "session.delete" | "session.remove" => {
            let id = p["sessionId"]
                .as_str()
                .or_else(|| p["id"].as_str())
                .context("missing sessionId")?;
            state.agy.cancel(id).await?;
            state.db.delete_session(id)?;
            state.emit("session.removed", json!({"id":id}))?;
            Ok(json!({"removed":true}))
        }
        "session.archive" => {
            let id = str_param(p, "id")?;
            state
                .db
                .archive_session(id, p["archived"].as_bool().unwrap_or(true))?;
            let s = state.db.session(id)?.context("session not found")?;
            state.emit("session.changed", s.clone())?;
            Ok(s)
        }
        "session.permissions.set" => {
            let id = str_param(p, "sessionId")?;
            state.db.set_permission_mode(id, str_param(p, "mode")?)?;
            let session = state.db.session(id)?.context("session not found")?;
            state.emit("session.changed", session.clone())?;
            Ok(session)
        }
        "session.model.set" | "session.set_model" => {
            let id = str_param(p, "sessionId")?;
            let model = p["model"].as_str();
            let session = state.db.set_session_model(id, model)?;
            state.emit("session.changed", session.clone())?;
            Ok(session)
        }
        "session.send" => {
            let id = str_param(p, "sessionId")?;
            let content = p["content"].clone();
            if let Some(model) = content["model"].as_str() {
                let _ = state.db.set_session_model(id, Some(model));
                if let Some(session) = state.db.session(id)? {
                    state.emit("session.changed", session)?;
                }
            }
            for attachment in content["attachments"].as_array().into_iter().flatten() {
                state.db.save_attachment(
                    id,
                    Path::new(
                        attachment["path"]
                            .as_str()
                            .context("attachment path missing")?,
                    ),
                )?;
            }
            if p["delivery"] == "steer" {
                let text = content["text"].as_str().unwrap_or_default();
                let attachments = content["attachments"]
                    .as_array()
                    .into_iter()
                    .flatten()
                    .filter_map(|attachment| attachment["path"].as_str().map(PathBuf::from))
                    .collect::<Vec<_>>();
                state.agy.steer(id, text, &attachments)?;
                let msg = state.db.add_message(id, "user", content, "completed")?;
                state.emit("message.changed", msg.clone())?;
                return Ok(msg);
            }
            if state.db.session(id)?.is_some_and(|session| {
                matches!(
                    session["title"].as_str(),
                    Some("New session" | "Quick chat")
                )
            }) && let Some(title) = session_title(&content)
            {
                state.db.set_session_title(id, &title)?;
                if let Some(session) = state.db.session(id)? {
                    state.emit("session.changed", session)?;
                }
            }
            let msg = state.db.add_message(id, "user", content, "queued")?;
            state.emit("message.changed", msg.clone())?;
            let turn = state
                .db
                .create_turn(id, msg["id"].as_str().context("message id missing")?)?;
            state.emit("turn.changed", turn)?;
            if !state.workers.lock().unwrap().contains(id) {
                state.db.set_session_status(id, "queued")?;
                state.emit("session.status", json!({"id":id,"status":"queued"}))?;
            }
            start_worker(state.clone(), id.to_owned());
            Ok(msg)
        }
        "session.queue.remove" => {
            let id = str_param(p, "messageId")?;
            if let Some(turn) = state.db.turn_for_message(id)? {
                set_turn_status(state, turn["id"].as_str().unwrap_or_default(), "cancelled")?;
            }
            state.db.remove_queued_message(id)?;
            state.emit("message.removed", json!({"id":id}))?;
            Ok(json!({"removed":true}))
        }
        "session.cancel" => {
            let id = str_param(p, "sessionId")?;
            state.db.set_session_status(id, "cancelled")?;
            state.emit("session.status", json!({"id":id,"status":"cancelled"}))?;
            if let Some(turn) = state.db.set_active_turn_status(id, "cancelled")? {
                state.emit("turn.changed", turn)?;
            }
            state.agy.cancel(id).await?;
            Ok(json!({"cancelled":true}))
        }
        "session.task.stop" => {
            let session_id = str_param(p, "sessionId")?;
            let task_id = str_param(p, "taskId")?;
            let (prompt, description) = state.agy.stop_task(session_id, task_id)?;
            let message = state.db.add_message(
                session_id,
                "user",
                json!({
                    "text":prompt,
                    "attachments":[],
                    "control":{
                        "type":"task_stopped",
                        "taskId":task_id,
                        "description":description,
                    }
                }),
                "completed",
            )?;
            state.emit("message.changed", message.clone())?;
            Ok(json!({"stopped":true,"taskId":task_id,"message":message}))
        }
        "session.permission.respond" => {
            let id = str_param(p, "sessionId")?;
            let allow = p["allow"].as_bool().context("missing allow")?;
            state.agy.respond_permission(id, allow)?;
            state.db.set_session_status(id, "running")?;
            if let Some(turn) = state.db.set_active_turn_status(id, "running")? {
                state.emit("turn.changed", turn)?;
            }
            state.emit(
                "session.status",
                json!({"id":id,"status":"running","permissionResolved":true}),
            )?;
            Ok(json!({"accepted":true,"allow":allow}))
        }
        "session.input.respond" => {
            let id = str_param(p, "sessionId")?;
            let selected_indices = p["selectedIndices"]
                .as_array()
                .context("missing selectedIndices")?
                .iter()
                .map(|value| {
                    value
                        .as_u64()
                        .context("invalid selected index")
                        .map(|value| value as usize)
                })
                .collect::<Result<Vec<_>>>()?;
            state.agy.respond_input(id, &selected_indices)?;
            state.db.set_session_status(id, "running")?;
            if let Some(turn) = state.db.set_active_turn_status(id, "running")? {
                state.emit("turn.changed", turn)?;
            }
            state.emit(
                "session.status",
                json!({"id":id,"status":"running","inputResolved":true}),
            )?;
            Ok(json!({"accepted":true}))
        }
        "history.scan" => {
            let sessions = state.db.sessions(None, true)?;
            let projects = state.db.projects()?;
            let mut conversations = state.agy.history()?;
            for conversation in &mut conversations {
                let Some(conversation_id) = conversation["conversationId"].as_str() else {
                    continue;
                };
                if let Some(session) = sessions
                    .iter()
                    .find(|session| session["externalId"].as_str() == Some(conversation_id))
                {
                    conversation["importedSessionId"] = session["id"].clone();
                    conversation["importedProjectId"] = session["projectId"].clone();
                }
                let Some(cwd) = conversation["cwd"].as_str() else {
                    continue;
                };
                let canonical_cwd = Path::new(cwd).canonicalize().ok();
                if let Some(project) = projects.iter().find(|project| {
                    project["folders"].as_array().is_some_and(|folders| {
                        folders.iter().any(|folder| {
                            folder["path"].as_str().map(Path::new).is_some_and(|path| {
                                canonical_cwd.as_ref().is_some_and(|cwd| {
                                    path.canonicalize().ok().as_ref() == Some(cwd)
                                })
                            })
                        })
                    })
                }) {
                    conversation["suggestedProjectId"] = project["id"].clone();
                    conversation["suggestedProjectName"] = project["name"].clone();
                }
            }
            Ok(json!({"conversations":conversations}))
        }
        "history.import" => {
            let conversation_id = str_param(p, "conversationId")?;
            if let Some(session) = state
                .db
                .sessions(None, true)?
                .into_iter()
                .find(|session| session["externalId"].as_str() == Some(conversation_id))
            {
                return Ok(session);
            }
            let s = state.db.create_session(
                p["projectId"].as_str(),
                p["title"].as_str(),
                "agy",
                Some(conversation_id),
                &data_dir().join("sessions"),
            )?;
            let session_id = s["id"].as_str().context("imported session has no id")?;
            import_conversation_events(
                state,
                session_id,
                state.agy.import_history(conversation_id)?,
            )?;
            state.emit("session.changed", s.clone())?;
            Ok(s)
        }
        "provider.commands" => Ok(json!({"commands":state.agy.commands()})),
        "provider.list" => Ok(json!({"providers":[state.agy.detect()]})),
        "provider.models" => Ok(json!({"models":state.agy.models()?})),
        "provider.auth.status" => Ok(json!({"auth":state.agy.auth_status().await?})),
        "provider.auth.start" => {
            let session_id = state.agy.start_auth()?;
            Ok(json!({"auth":state.agy.auth_flow(&session_id)?}))
        }
        "provider.auth.flow" => Ok(json!({
            "auth":state.agy.auth_flow(str_param(p, "sessionId")?)?
        })),
        "provider.auth.submit" => Ok(json!({
            "auth":state.agy.submit_auth_code(
                str_param(p, "sessionId")?,
                str_param(p, "code")?,
            )?
        })),
        "provider.auth.cancel" => Ok(json!({
            "auth":state.agy.cancel_auth(str_param(p, "sessionId")?)?
        })),
        "fs.list" => files::list(
            &files::path_from(p, "path")?,
            p["offset"].as_u64().unwrap_or(0) as usize,
            p["limit"].as_u64().unwrap_or(200) as usize,
        ),
        "fs.read" => files::read(&files::path_from(p, "path")?),
        "fs.write" => files::write(
            &files::path_from(p, "path")?,
            str_param(p, "text")?,
            p["expectedRevision"].as_str(),
        ),
        "fs.mkdir" => {
            files::mkdir(&files::path_from(p, "path")?)?;
            Ok(json!({"created":true}))
        }
        "fs.delete" => {
            files::delete(&files::path_from(p, "path")?)?;
            Ok(json!({"deleted":true}))
        }
        "fs.rename" => {
            files::rename(&files::path_from(p, "from")?, &files::path_from(p, "to")?)?;
            Ok(json!({"renamed":true}))
        }
        "fs.search" => files::search(
            &files::path_from(p, "root")?,
            str_param(p, "query")?,
            p["limit"].as_u64().unwrap_or(100) as usize,
        ),
        "fs.diff" => files::git_diff(
            &files::path_from(p, "root")?,
            p["path"].as_str().map(Path::new),
        ),
        "fs.upload" => {
            let bytes = STANDARD.decode(str_param(p, "base64")?)?;
            if bytes.len() > riz_protocol::MAX_ATTACHMENT_BYTES {
                bail!("attachment exceeds 25 MiB")
            };
            files::upload(&files::path_from(p, "path")?, &bytes)
        }
        "fs.upload.begin" => {
            let size = p["size"].as_u64().context("missing size")? as usize;
            if size > riz_protocol::MAX_ATTACHMENT_BYTES {
                bail!("attachment exceeds 25 MiB")
            }
            let id = Uuid::new_v4();
            state.uploads.lock().unwrap().insert(
                id,
                UploadTransfer {
                    path: files::path_from(p, "path")?,
                    expected_size: size,
                    bytes: Vec::with_capacity(size),
                },
            );
            Ok(json!({"transferId":id,"chunkBytes":riz_protocol::FILE_CHUNK_BYTES}))
        }
        "fs.upload.finish" => {
            let id = uuid_param(p, "transferId")?;
            let transfer = state
                .uploads
                .lock()
                .unwrap()
                .remove(&id)
                .context("upload transfer not found")?;
            if transfer.bytes.len() != transfer.expected_size {
                bail!(
                    "incomplete upload: expected {}, received {}",
                    transfer.expected_size,
                    transfer.bytes.len()
                )
            }
            files::upload(&transfer.path, &transfer.bytes)
        }
        "fs.download" => {
            let transfer_id = uuid_param(p, "transferId")?;
            let (metadata, bytes) = files::download(
                &files::path_from(p, "path")?,
                riz_protocol::MAX_ATTACHMENT_BYTES,
            )?;
            for chunk in bytes.chunks(riz_protocol::FILE_CHUNK_BYTES) {
                let _ = state.outbound.send(Outbound::Binary(encode_binary(
                    BinaryChannel::File,
                    transfer_id,
                    chunk,
                )));
            }
            Ok(metadata)
        }
        "skill.list" => {
            let project = p["projectPath"].as_str().map(Path::new);
            let result = skills::list(project)?;
            for skill in result["skills"].as_array().into_iter().flatten() {
                state.db.save_skill_source(
                    skill["scope"].as_str().unwrap_or("project"),
                    Path::new(skill["path"].as_str().context("skill path missing")?),
                    skill.get("source").filter(|source| !source.is_null()),
                    skill["enabled"].as_bool().unwrap_or(true),
                )?;
            }
            Ok(result)
        }
        "skill.read" => skills::read(&files::path_from(p, "path")?),
        "skill.write" => {
            let path = files::path_from(p, "path")?;
            let result = skills::write(&path, str_param(p, "content")?)?;
            state
                .db
                .save_skill_source(skill_scope(&path), &path, None, true)?;
            Ok(result)
        }
        "skill.delete" => {
            let path = files::path_from(p, "path")?;
            skills::delete(&path)?;
            state.db.remove_skill_source(&path)?;
            Ok(json!({"deleted":true}))
        }
        "skill.toggle" => {
            let path = files::path_from(p, "path")?;
            let source = skills::read_source(&path);
            let enabled = p["enabled"].as_bool().unwrap_or(true);
            let result = skills::toggle(&path, enabled)?;
            let target = Path::new(result["path"].as_str().context("skill path missing")?);
            state.db.remove_skill_source(&path)?;
            state
                .db
                .save_skill_source(skill_scope(target), target, source.as_ref(), enabled)?;
            Ok(result)
        }
        "skill.git.install" => {
            let result = skills::install_git(
                &files::path_from(p, "targetRoot")?,
                str_param(p, "url")?,
                p["reference"].as_str(),
            )?;
            let source = json!({"url":result["url"],"reference":result["reference"],"commit":result["commit"]});
            for installed in result["installed"].as_array().into_iter().flatten() {
                let path = Path::new(
                    installed["path"]
                        .as_str()
                        .context("installed skill path missing")?,
                );
                state
                    .db
                    .save_skill_source(skill_scope(path), path, Some(&source), true)?;
            }
            Ok(result)
        }
        "skill.git.update" => {
            let path = files::path_from(p, "path")?;
            let result = skills::update_git(&path)?;
            let source = json!({"url":result["url"],"reference":result["reference"],"commit":result["commit"]});
            state
                .db
                .save_skill_source(skill_scope(&path), &path, Some(&source), true)?;
            Ok(result)
        }
        "quota.get" => {
            let q = state.agy.quota().await?;
            state.db.save_quota(q)
        }
        "terminal.list" => Ok(state
            .terminals
            .list(p.get("cwd").and_then(Value::as_str).map(Path::new))),
        "terminal.create" => state.terminals.create(
            p.get("projectId")
                .and_then(Value::as_str)
                .map(Uuid::parse_str)
                .transpose()?,
            &files::path_from(p, "cwd")?,
            p["cols"].as_u64().unwrap_or(100) as u16,
            p["rows"].as_u64().unwrap_or(30) as u16,
        ),
        "terminal.input" => {
            state.terminals.input(
                uuid_param(p, "id")?,
                STANDARD.decode(str_param(p, "base64")?)?.as_slice(),
            )?;
            Ok(json!({"written":true}))
        }
        "terminal.resize" => {
            state.terminals.resize(
                uuid_param(p, "id")?,
                p["cols"].as_u64().unwrap_or(100) as u16,
                p["rows"].as_u64().unwrap_or(30) as u16,
            )?;
            Ok(json!({"resized":true}))
        }
        "terminal.replay" => {
            let id = uuid_param(p, "id")?;
            Ok(json!({"base64":STANDARD.encode(state.terminals.replay(id)?)}))
        }
        "terminal.close" => {
            state.terminals.close(uuid_param(p, "id")?)?;
            Ok(json!({"closed":true}))
        }
        _ => bail!("unknown method: {method}"),
    }
}

fn start_worker(state: AppState, session_id: String) {
    if !state.workers.lock().unwrap().insert(session_id.clone()) {
        return;
    }
    let quota_state = state.clone();
    let quota_session = session_id.clone();
    tokio::spawn(async move {
        loop {
            tokio::time::sleep(Duration::from_secs(60)).await;
            if !quota_state.workers.lock().unwrap().contains(&quota_session) {
                break;
            }
            if let Ok(snapshot) = quota_state.agy.quota().await {
                let _ = quota_state.db.save_quota(snapshot);
            }
        }
    });
    tokio::spawn(async move {
        loop {
            let queued = state.db.queued_messages(&session_id).unwrap_or_default();
            let Some(m) = queued.first() else { break };
            let message_id = m["id"].as_str().unwrap_or_default().to_owned();
            let turn = match state.db.turn_for_message(&message_id) {
                Ok(Some(turn)) => turn,
                Ok(None) => match state.db.create_turn(&session_id, &message_id) {
                    Ok(turn) => turn,
                    Err(_) => break,
                },
                Err(_) => break,
            };
            let turn_id = turn["id"].as_str().unwrap_or_default().to_owned();
            let content = m["content"].clone();
            let text = content["text"]
                .as_str()
                .or_else(|| content.as_str())
                .unwrap_or_default()
                .to_owned();
            let attachments = content["attachments"]
                .as_array()
                .map(|a| {
                    a.iter()
                        .filter_map(|v| v["path"].as_str().map(PathBuf::from))
                        .collect()
                })
                .unwrap_or_default();
            let Some(session) = state.db.session(&session_id).ok().flatten() else {
                break;
            };
            let Ok(context) = state.db.execution_context(&session_id) else {
                break;
            };
            let _ = state.db.set_turn_context(
                &turn_id,
                Path::new(context["cwd"].as_str().unwrap_or_default()),
                &context["additionalDirectories"],
            );
            let _ = state
                .db
                .update_message(&message_id, content.clone(), "running");
            let _ = set_turn_status(&state, &turn_id, "running");
            let _ = state.db.set_session_status(&session_id, "running");
            let _ = state.emit(
                "session.status",
                json!({"id":session_id,"status":"running"}),
            );
            if text.trim() == "/usage" {
                match state.agy.quota().await {
                    Ok(snapshot) => {
                        let _ = state.db.save_quota(snapshot.clone());
                        let _ = state.db.update_message(&message_id, content, "completed");
                        let _ = set_turn_status(&state, &turn_id, "completed");
                        let assistant = state
                            .db
                            .add_message(
                                &session_id,
                                "assistant",
                                json!({"text":quota_markdown(&snapshot),"structuredEvents":[]}),
                                "completed",
                            )
                            .ok();
                        if let Some(message) = assistant {
                            let _ = state.emit("message.changed", message);
                        }
                        let _ = state.db.set_session_status(&session_id, "completed");
                        let _ = state.emit(
                            "session.status",
                            json!({"id":session_id,"status":"completed"}),
                        );
                    }
                    Err(error) => {
                        let _ = state.db.update_message(&message_id, content, "failed");
                        let _ = set_turn_status(&state, &turn_id, "failed");
                        let _ = state.db.set_session_status(&session_id, "failed");
                        let _ = state.emit(
                            "session.status",
                            json!({"id":session_id,"status":"failed","error":error.to_string()}),
                        );
                    }
                }
                continue;
            }
            let event_state = state.clone();
            let event_session_id = session_id.clone();
            let event_turn_id = turn_id.clone();
            let live_assistant_id = Arc::new(Mutex::new(None::<String>));
            let live_text = Arc::new(Mutex::new(String::new()));
            let live_structured_events = Arc::new(Mutex::new(Vec::<Value>::new()));
            let live_event_fingerprints = Arc::new(Mutex::new(HashSet::<String>::new()));
            let callback_assistant_id = live_assistant_id.clone();
            let callback_text = live_text.clone();
            let callback_structured_events = live_structured_events.clone();
            let callback_fingerprints = live_event_fingerprints.clone();
            let request = PromptRequest {
                session_id: session_id.clone(),
                cwd: PathBuf::from(context["cwd"].as_str().unwrap_or_default()),
                additional_directories: context["additionalDirectories"]
                    .as_array()
                    .into_iter()
                    .flatten()
                    .filter_map(|path| path.as_str().map(PathBuf::from))
                    .collect(),
                prompt: text,
                conversation_id: session["externalId"].as_str().map(str::to_owned),
                provider_project_id: {
                    let (scope_type, scope_id) =
                        if let Some(project_id) = session["projectId"].as_str() {
                            ("project", project_id)
                        } else {
                            ("session", session_id.as_str())
                        };
                    state
                        .db
                        .provider_binding("agy", scope_type, scope_id)
                        .ok()
                        .flatten()
                },
                model: content["model"]
                    .as_str()
                    .or_else(|| session["model"].as_str())
                    .map(str::to_owned),
                mode: content["mode"].as_str().map(str::to_owned),
                permission_mode: session["permissionMode"]
                    .as_str()
                    .unwrap_or("ask")
                    .to_owned(),
                attachments,
                on_event: Arc::new(move |event| match event {
                    ProviderRuntimeEvent::PermissionRequested { question, detail } => {
                        let _ = event_state
                            .db
                            .set_session_status(&event_session_id, "waiting_permission");
                        let _ = set_turn_status(&event_state, &event_turn_id, "waiting_permission");
                        let _ = event_state.emit(
                            "permission.requested",
                            json!({"sessionId":event_session_id,"question":question,"detail":detail}),
                        );
                    }
                    ProviderRuntimeEvent::InputRequested { input } => {
                        let _ = event_state
                            .db
                            .set_session_status(&event_session_id, "waiting_input");
                        let _ = set_turn_status(&event_state, &event_turn_id, "waiting_input");
                        let _ = event_state.emit(
                            "input.requested",
                            json!({"sessionId":event_session_id,"input":input}),
                        );
                    }
                    ProviderRuntimeEvent::Structured { event } => {
                        if !callback_fingerprints
                            .lock()
                            .unwrap()
                            .insert(event.to_string())
                        {
                            return;
                        }
                        let _ = event_state
                            .db
                            .add_structured_event(&event_session_id, &event);
                        let _ = event_state.emit(
                            "agent.structured",
                            json!({"sessionId":event_session_id,"event":event.clone()}),
                        );
                        let structured_events = {
                            let mut events = callback_structured_events.lock().unwrap();
                            upsert_runtime_event(&mut events, event);
                            events.clone()
                        };
                        let text = callback_text.lock().unwrap().clone();
                        let message = update_live_assistant(
                            &event_state,
                            &event_session_id,
                            &callback_assistant_id,
                            text,
                            structured_events,
                        );
                        if let Some(message) = message {
                            let _ = event_state.emit("message.changed", message);
                        }
                    }
                    ProviderRuntimeEvent::TextSnapshot { text } => {
                        *callback_text.lock().unwrap() = text.clone();
                        let structured_events = callback_structured_events.lock().unwrap().clone();
                        let message = update_live_assistant(
                            &event_state,
                            &event_session_id,
                            &callback_assistant_id,
                            text,
                            structured_events,
                        );
                        if let Some(message) = message {
                            let _ = event_state.emit("message.changed", message);
                        }
                    }
                }),
            };
            match state.agy.prompt(request).await {
                Ok(result) => {
                    if session_is_cancelled(&state, &session_id) {
                        finalize_cancelled_messages(
                            &state,
                            &message_id,
                            &content,
                            &live_assistant_id,
                        );
                        let _ = set_turn_status(&state, &turn_id, "cancelled");
                        break;
                    }
                    let _ = state.db.update_message(&message_id, content, "completed");
                    let _ = set_turn_status(&state, &turn_id, "completed");
                    let context_unchanged = state
                        .db
                        .execution_context(&session_id)
                        .is_ok_and(|current| current == context);
                    if context_unchanged && let Some(id) = result.conversation_id.as_deref() {
                        let _ = state.db.set_external_id(
                            &session_id,
                            id,
                            result.provider_project_id.as_deref(),
                            Path::new(context["cwd"].as_str().unwrap_or_default()),
                            &context["additionalDirectories"],
                        );
                    }
                    if context_unchanged && let Some(project_id) = result.provider_project_id {
                        let (scope_type, scope_id) = if let Some(id) = session["projectId"].as_str()
                        {
                            ("project", id)
                        } else {
                            ("session", session_id.as_str())
                        };
                        let _ =
                            state
                                .db
                                .set_provider_binding("agy", scope_type, scope_id, &project_id);
                    }
                    let structured_events = result.events;
                    let live_fingerprints = live_event_fingerprints.lock().unwrap().clone();
                    for event in &structured_events {
                        if live_fingerprints.contains(&event.to_string()) {
                            continue;
                        }
                        let _ = state.db.add_structured_event(&session_id, event);
                        let _ = state.emit(
                            "agent.structured",
                            json!({"sessionId":session_id,"event":event}),
                        );
                    }
                    let assistant_content = json!({
                        "text": result.text,
                        "diagnostic": result.diagnostic,
                        "structuredEvents": structured_events,
                    });
                    let existing_assistant_id = live_assistant_id.lock().unwrap().clone();
                    let assistant = if let Some(id) = existing_assistant_id {
                        let _ = state.db.update_message(&id, assistant_content, "completed");
                        state.db.message(&id).ok().flatten()
                    } else {
                        state
                            .db
                            .add_message(&session_id, "assistant", assistant_content, "completed")
                            .ok()
                    };
                    if let Some(a) = assistant {
                        let _ = state.emit("message.changed", a);
                    }
                    let _ = state.db.set_session_status(&session_id, "completed");
                    let _ = state.emit(
                        "session.status",
                        json!({"id":session_id,"status":"completed"}),
                    );
                }
                Err(e) => {
                    if session_is_cancelled(&state, &session_id) {
                        finalize_cancelled_messages(
                            &state,
                            &message_id,
                            &content,
                            &live_assistant_id,
                        );
                        let _ = set_turn_status(&state, &turn_id, "cancelled");
                        break;
                    }
                    let _ = state.db.update_message(&message_id, content, "failed");
                    let assistant_content = json!({
                        "text": live_text.lock().unwrap().clone(),
                        "diagnostic": e.to_string(),
                        "structuredEvents": live_structured_events.lock().unwrap().clone(),
                    });
                    let assistant = if let Some(id) = live_assistant_id.lock().unwrap().clone() {
                        let _ = state.db.update_message(&id, assistant_content, "failed");
                        state.db.message(&id).ok().flatten()
                    } else {
                        state
                            .db
                            .add_message(&session_id, "assistant", assistant_content, "failed")
                            .ok()
                    };
                    if let Some(message) = assistant {
                        let _ = state.emit("message.changed", message);
                    }
                    let _ = set_turn_status(&state, &turn_id, "failed");
                    let _ = state.db.set_session_status(&session_id, "failed");
                    let _ = state.emit(
                        "session.status",
                        json!({"id":session_id,"status":"failed","error":e.to_string()}),
                    );
                }
            }
        }
        state.workers.lock().unwrap().remove(&session_id);
        if let Ok(snapshot) = state.agy.quota().await {
            let _ = state.db.save_quota(snapshot);
        }
    });
}

fn set_turn_status(state: &AppState, turn_id: &str, status: &str) -> Result<Value> {
    let turn = state.db.set_turn_status(turn_id, status)?;
    state.emit("turn.changed", turn.clone())?;
    Ok(turn)
}

fn session_is_cancelled(state: &AppState, session_id: &str) -> bool {
    state
        .db
        .session(session_id)
        .ok()
        .flatten()
        .is_some_and(|session| session["status"] == "cancelled")
}

fn finalize_cancelled_messages(
    state: &AppState,
    user_message_id: &str,
    user_content: &Value,
    live_assistant_id: &Arc<Mutex<Option<String>>>,
) {
    let _ = state
        .db
        .update_message(user_message_id, user_content.clone(), "cancelled");
    if let Ok(Some(message)) = state.db.message(user_message_id) {
        let _ = state.emit("message.changed", message);
    }
    let assistant_id = live_assistant_id.lock().unwrap().clone();
    if let Some(id) = assistant_id
        && let Ok(Some(message)) = state.db.message(&id)
    {
        let _ = state
            .db
            .update_message(&id, message["content"].clone(), "cancelled");
        if let Ok(Some(message)) = state.db.message(&id) {
            let _ = state.emit("message.changed", message);
        }
    }
}

fn quota_markdown(snapshot: &Value) -> String {
    let mut lines = vec!["### Quota".to_owned()];
    for model in snapshot["models"].as_array().into_iter().flatten() {
        let name = model["modelId"].as_str().unwrap_or("Unknown model");
        let remaining = model["remainingPercentage"].as_f64().unwrap_or(0.0);
        let mut line = format!("- **{name}**: {remaining:.0}% remaining");
        if let Some(refresh) = model["refreshIn"].as_str() {
            line.push_str(&format!(" (refreshes in {refresh})"));
        }
        lines.push(line);
    }
    if lines.len() == 1 {
        lines.push("Quota data is unavailable.".to_owned());
    }
    lines.join("\n")
}

fn session_title(content: &Value) -> Option<String> {
    let raw = content["text"].as_str().or_else(|| content.as_str())?;
    let compact = raw.split_whitespace().collect::<Vec<_>>().join(" ");
    if compact.is_empty() {
        return None;
    }
    let mut title = compact.chars().take(56).collect::<String>();
    if compact.chars().count() > 56 {
        title.push_str("...");
    }
    Some(title)
}

fn upsert_runtime_event(events: &mut Vec<Value>, event: Value) {
    let slot = events.iter().position(|existing| {
        !event["index"].is_null()
            && existing["index"] == event["index"]
            && existing["type"] == event["type"]
            && existing["name"] == event["name"]
    });
    if let Some(index) = slot {
        events[index] = event;
    } else {
        events.push(event);
    }
}

fn update_live_assistant(
    state: &AppState,
    session_id: &str,
    assistant_id: &Mutex<Option<String>>,
    text: String,
    structured_events: Vec<Value>,
) -> Option<Value> {
    let content = json!({
        "text": text,
        "structuredEvents": structured_events,
    });
    let existing_id = assistant_id.lock().unwrap().clone();
    if let Some(id) = existing_id {
        let _ = state.db.update_message(&id, content, "running");
        state.db.message(&id).ok().flatten()
    } else {
        let message = state
            .db
            .add_message(session_id, "assistant", content, "running")
            .ok();
        if let Some(message) = &message {
            *assistant_id.lock().unwrap() = message["id"].as_str().map(str::to_owned);
        }
        message
    }
}

fn import_conversation_events(
    state: &AppState,
    session_id: &str,
    events: Vec<Value>,
) -> Result<()> {
    let mut structured = Vec::new();
    for event in events {
        match event["type"].as_str().unwrap_or("tool") {
            "user" => {
                if !structured.is_empty() {
                    state.db.add_message(
                        session_id,
                        "assistant",
                        json!({"text":"","structuredEvents":structured}),
                        "completed",
                    )?;
                    structured = Vec::new();
                }
                state.db.add_message(
                    session_id,
                    "user",
                    json!({"text":event["text"].as_str().unwrap_or_default()}),
                    "completed",
                )?;
            }
            "text" => {
                state.db.add_message(
                    session_id,
                    "assistant",
                    json!({"text":event["text"].as_str().unwrap_or_default(),"structuredEvents":structured}),
                    "completed",
                )?;
                structured = Vec::new();
            }
            "title" => {}
            _ => {
                state.db.add_structured_event(session_id, &event)?;
                structured.push(event);
            }
        }
    }
    if !structured.is_empty() {
        state.db.add_message(
            session_id,
            "assistant",
            json!({"text":"","structuredEvents":structured}),
            "completed",
        )?;
    }
    Ok(())
}

fn handle_binary(state: &AppState, frame: &[u8]) -> Result<()> {
    let (channel, id, data) = decode_binary(frame).context("invalid binary frame")?;
    match channel {
        BinaryChannel::Terminal => state.terminals.input(id, data),
        BinaryChannel::Attachment | BinaryChannel::File => {
            let mut uploads = state.uploads.lock().unwrap();
            let transfer = uploads.get_mut(&id).context("upload transfer not found")?;
            if data.len() > riz_protocol::FILE_CHUNK_BYTES {
                bail!("file chunk exceeds 256 KiB")
            }
            if transfer.bytes.len() + data.len() > transfer.expected_size {
                bail!("upload exceeds declared size")
            }
            transfer.bytes.extend_from_slice(data);
            Ok(())
        }
    }
}
fn wire_event(daemon_id: Uuid, seq: i64, topic: &str, payload: Value) -> Envelope {
    Envelope {
        v: PROTOCOL_VERSION,
        kind: "event".into(),
        request_id: None,
        daemon_id: Some(daemon_id),
        seq: Some(seq),
        payload: json!({"topic":topic,"data":payload}),
        error: None,
    }
}
fn str_param<'a>(p: &'a Value, key: &str) -> Result<&'a str> {
    p[key].as_str().with_context(|| format!("missing {key}"))
}
fn uuid_param(p: &Value, key: &str) -> Result<Uuid> {
    Ok(Uuid::parse_str(str_param(p, key)?)?)
}

fn skill_scope(path: &Path) -> &'static str {
    if path.starts_with(skills::global_dir()) {
        "global"
    } else {
        "project"
    }
}

#[allow(dead_code)]
fn terminal_frame(id: Uuid, data: &[u8]) -> Vec<u8> {
    encode_binary(BinaryChannel::Terminal, id, data)
}

#[cfg(test)]
mod tests {
    use super::{
        MAX_INITIAL_EVENT_REPLAY, dispatch, quota_markdown, router, session_title,
        upsert_runtime_event,
    };
    use crate::{
        config::{Config, hash_token},
        db::Database,
        state::AppState,
    };
    use futures_util::{SinkExt, StreamExt};
    use riz_protocol::{
        BinaryChannel, Envelope, FILE_CHUNK_BYTES, PROTOCOL_VERSION, decode_binary, encode_binary,
    };
    use serde_json::json;
    use std::time::Duration;
    use tempfile::TempDir;
    use tokio::task::JoinHandle;
    use tokio_tungstenite::{
        MaybeTlsStream, WebSocketStream, connect_async, tungstenite::Message as ClientMessage,
    };
    use uuid::Uuid;

    type Client = WebSocketStream<MaybeTlsStream<tokio::net::TcpStream>>;

    async fn test_server(event_count: usize) -> (TempDir, String, JoinHandle<()>) {
        let directory = tempfile::tempdir().unwrap();
        let database = Database::open(&directory.path().join("riz.db")).unwrap();
        for index in 0..event_count {
            database
                .append_event("test.event", json!({"index":index}))
                .unwrap();
        }
        let state = AppState::new(
            Config {
                daemon_id: Uuid::new_v4(),
                name: "Test daemon".into(),
                listen: "127.0.0.1:0".parse().unwrap(),
                token_hash: hash_token("secret"),
                issued_tokens: Vec::new(),
                relay: None,
            },
            database,
        );
        let listener = tokio::net::TcpListener::bind("127.0.0.1:0").await.unwrap();
        let address = listener.local_addr().unwrap();
        let handle = tokio::spawn(async move {
            axum::serve(listener, router(state)).await.unwrap();
        });
        (directory, format!("ws://{address}/ws"), handle)
    }

    fn auth(token: &str, last_seq: i64) -> ClientMessage {
        ClientMessage::Text(
            serde_json::to_string(&Envelope {
                v: PROTOCOL_VERSION,
                kind: "auth".into(),
                request_id: Some("auth-test".into()),
                daemon_id: None,
                seq: None,
                payload: json!({"token":token,"lastSeq":last_seq}),
                error: None,
            })
            .unwrap()
            .into(),
        )
    }

    fn request(id: &str, method: &str, params: serde_json::Value) -> ClientMessage {
        ClientMessage::Text(
            serde_json::to_string(&Envelope {
                v: PROTOCOL_VERSION,
                kind: "request".into(),
                request_id: Some(id.into()),
                daemon_id: None,
                seq: None,
                payload: json!({"method":method,"params":params}),
                error: None,
            })
            .unwrap()
            .into(),
        )
    }

    async fn receive(client: &mut Client) -> Envelope {
        let message = client.next().await.unwrap().unwrap();
        let ClientMessage::Text(text) = message else {
            panic!("expected text frame")
        };
        serde_json::from_str(&text).unwrap()
    }

    async fn receive_response(client: &mut Client, request_id: &str) -> Envelope {
        loop {
            let envelope = receive(client).await;
            if envelope.request_id.as_deref() == Some(request_id) {
                return envelope;
            }
        }
    }

    async fn receive_event(client: &mut Client, topic: &str) -> Envelope {
        loop {
            let envelope = receive(client).await;
            if envelope.payload["topic"] == topic {
                return envelope;
            }
        }
    }

    #[tokio::test]
    async fn websocket_rejects_an_invalid_token() {
        let (_directory, url, server) = test_server(0).await;
        let (mut client, _) = connect_async(url).await.unwrap();
        client.send(auth("wrong", 0)).await.unwrap();
        let response = receive(&mut client).await;
        assert_eq!(response.error.unwrap().code, "unauthorized");
        server.abort();
    }

    #[tokio::test]
    async fn websocket_closes_when_authentication_times_out() {
        let (_directory, url, server) = test_server(0).await;
        let (mut client, _) = connect_async(url).await.unwrap();
        let closed = tokio::time::timeout(Duration::from_secs(7), client.next())
            .await
            .expect("server did not enforce the five second auth timeout");
        assert!(closed.is_none() || closed.is_some_and(|result| result.is_err()));
        server.abort();
    }

    #[tokio::test]
    async fn websocket_replays_events_or_falls_back_to_a_snapshot() {
        let (_small_directory, small_url, small_server) = test_server(2).await;
        let (mut small_client, _) = connect_async(small_url).await.unwrap();
        small_client.send(auth("secret", 0)).await.unwrap();
        assert_eq!(receive(&mut small_client).await.payload["kind"], "hello");
        let first = receive(&mut small_client).await;
        let second = receive(&mut small_client).await;
        assert_eq!(first.payload["topic"], "test.event");
        assert_eq!(first.seq, Some(1));
        assert_eq!(second.seq, Some(2));
        small_server.abort();

        let event_count = MAX_INITIAL_EVENT_REPLAY + 1;
        let (_large_directory, large_url, large_server) = test_server(event_count).await;
        let (mut large_client, _) = connect_async(large_url).await.unwrap();
        large_client.send(auth("secret", 0)).await.unwrap();
        assert_eq!(receive(&mut large_client).await.payload["kind"], "hello");
        let snapshot = receive(&mut large_client).await;
        assert_eq!(snapshot.payload["topic"], "snapshot");
        assert_eq!(snapshot.seq, Some(event_count as i64));
        assert!(snapshot.payload["data"]["sessions"].is_array());
        large_server.abort();
    }

    #[tokio::test]
    async fn websocket_broadcasts_the_same_event_to_simultaneous_clients() {
        let (directory, url, server) = test_server(0).await;
        let (mut first, _) = connect_async(&url).await.unwrap();
        let (mut second, _) = connect_async(&url).await.unwrap();
        first.send(auth("secret", 0)).await.unwrap();
        second.send(auth("secret", 0)).await.unwrap();
        assert_eq!(receive(&mut first).await.payload["kind"], "hello");
        assert_eq!(receive(&mut second).await.payload["kind"], "hello");

        first
            .send(request(
                "add-project",
                "project.create",
                json!({"folders":[directory.path()],"name":"Shared event"}),
            ))
            .await
            .unwrap();
        let first_event = receive_event(&mut first, "project.changed").await;
        let second_event = receive_event(&mut second, "project.changed").await;
        assert_eq!(first_event.seq, second_event.seq);
        assert_eq!(first_event.payload["data"]["name"], "Shared event");
        server.abort();
    }

    #[tokio::test]
    async fn websocket_reports_daemon_update_status() {
        let (_directory, url, server) = test_server(0).await;
        let (mut client, _) = connect_async(url).await.unwrap();
        client.send(auth("secret", 0)).await.unwrap();
        assert_eq!(receive(&mut client).await.payload["kind"], "hello");
        client
            .send(request("update-status", "daemon.update.status", json!({})))
            .await
            .unwrap();
        let response = receive_response(&mut client, "update-status").await;
        assert_eq!(response.payload["repository"], "nerimoe/riz");
        assert_eq!(
            response.payload["currentVersion"],
            env!("CARGO_PKG_VERSION")
        );
        server.abort();
    }

    #[tokio::test]
    async fn websocket_uploads_and_downloads_multiple_binary_chunks() {
        let (directory, url, server) = test_server(0).await;
        let path = directory.path().join("chunked.bin");
        let expected = (0..FILE_CHUNK_BYTES * 2 + 17)
            .map(|index| (index % 251) as u8)
            .collect::<Vec<_>>();
        let (mut client, _) = connect_async(url).await.unwrap();
        client.send(auth("secret", 0)).await.unwrap();
        assert_eq!(receive(&mut client).await.payload["kind"], "hello");

        client
            .send(request(
                "upload-begin",
                "fs.upload.begin",
                json!({"path":path,"size":expected.len()}),
            ))
            .await
            .unwrap();
        let begin = receive_response(&mut client, "upload-begin").await;
        let upload_id = Uuid::parse_str(begin.payload["transferId"].as_str().unwrap()).unwrap();
        for chunk in expected.chunks(FILE_CHUNK_BYTES) {
            client
                .send(ClientMessage::Binary(
                    encode_binary(BinaryChannel::File, upload_id, chunk).into(),
                ))
                .await
                .unwrap();
        }
        client
            .send(request(
                "upload-finish",
                "fs.upload.finish",
                json!({"transferId":upload_id}),
            ))
            .await
            .unwrap();
        receive_response(&mut client, "upload-finish").await;
        assert_eq!(std::fs::read(&path).unwrap(), expected);

        let download_id = Uuid::new_v4();
        client
            .send(request(
                "download",
                "fs.download",
                json!({"path":path,"transferId":download_id}),
            ))
            .await
            .unwrap();
        let mut metadata = None;
        let mut downloaded = Vec::new();
        let mut chunk_sizes = Vec::new();
        while metadata.is_none() || downloaded.len() < expected.len() {
            match client.next().await.unwrap().unwrap() {
                ClientMessage::Text(text) => {
                    let envelope: Envelope = serde_json::from_str(&text).unwrap();
                    if envelope.request_id.as_deref() == Some("download") {
                        metadata = Some(envelope.payload);
                    }
                }
                ClientMessage::Binary(frame) => {
                    let (channel, id, payload) = decode_binary(&frame).unwrap();
                    if matches!(channel, BinaryChannel::File) && id == download_id {
                        chunk_sizes.push(payload.len());
                        downloaded.extend_from_slice(payload);
                    }
                }
                _ => {}
            }
        }
        assert_eq!(metadata.unwrap()["size"], expected.len());
        assert_eq!(downloaded, expected);
        assert_eq!(chunk_sizes, vec![FILE_CHUNK_BYTES, FILE_CHUNK_BYTES, 17]);
        server.abort();
    }

    #[test]
    fn formats_quota_command_output() {
        let output = quota_markdown(&json!({
            "models": [{
                "modelId": "Gemini weekly",
                "remainingPercentage": 53.0,
                "refreshIn": "36h 8m"
            }]
        }));
        assert!(output.contains("**Gemini weekly**: 53% remaining"));
        assert!(output.contains("refreshes in 36h 8m"));
    }

    #[test]
    fn derives_a_compact_session_title() {
        assert_eq!(
            session_title(&json!({"text":"  Read README.md, then run tests.  "})),
            Some("Read README.md, then run tests.".to_owned())
        );
    }

    #[test]
    fn replaces_runtime_event_lifecycle_updates_in_place() {
        let mut events = vec![json!({
            "index": 4,
            "type": "tool_call",
            "name": "read_file",
            "status": "RUNNING"
        })];
        upsert_runtime_event(
            &mut events,
            json!({
                "index": 4,
                "type": "tool_call",
                "name": "read_file",
                "status": "DONE"
            }),
        );
        assert_eq!(events.len(), 1);
        assert_eq!(events[0]["status"], "DONE");
    }

    #[tokio::test]
    async fn session_model_set_rpc_updates_and_emits_session_change() {
        let temp = tempfile::tempdir().unwrap();
        let db = Database::open(&temp.path().join("riz.db")).unwrap();
        let session = db
            .create_session(
                None,
                Some("Test"),
                "agy",
                None,
                &temp.path().join("sessions"),
            )
            .unwrap();
        let session_id = session["id"].as_str().unwrap();

        let state = AppState::new(
            Config {
                daemon_id: Uuid::new_v4(),
                name: "Test daemon".into(),
                listen: "127.0.0.1:0".parse().unwrap(),
                token_hash: hash_token("secret"),
                issued_tokens: Vec::new(),
                relay: None,
            },
            db.clone(),
        );

        let req = Envelope {
            v: PROTOCOL_VERSION,
            kind: "request".into(),
            request_id: Some("1".into()),
            daemon_id: None,
            seq: None,
            payload: json!({
                "method": "session.model.set",
                "params": {
                    "sessionId": session_id,
                    "model": "gemini-3.7-pro"
                }
            }),
            error: None,
        };
        let res = dispatch(&state, &req).await.unwrap();
        assert_eq!(res["model"], "gemini-3.7-pro");

        let fetched = db.session(session_id).unwrap().unwrap();
        assert_eq!(fetched["model"], "gemini-3.7-pro");
    }
}
