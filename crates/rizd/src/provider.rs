use anyhow::{Context, Result, bail};
use async_trait::async_trait;
#[cfg(unix)]
use nix::{
    sys::signal::{Signal, killpg},
    unistd::Pid,
};
use portable_pty::{ChildKiller, CommandBuilder, NativePtySystem, PtySize, PtySystem};
use riz_protocol::ProviderCapabilities;
use rusqlite::Connection;
use serde_json::{Value, json};
use std::{
    collections::{HashMap, HashSet},
    fs,
    io::{Read, Write},
    path::{Path, PathBuf},
    process::Command,
    sync::{
        Arc, Mutex,
        atomic::{AtomicBool, Ordering},
    },
    time::{Duration, SystemTime},
};
use url::Url;

#[derive(Clone)]
pub struct PromptRequest {
    pub session_id: String,
    pub cwd: PathBuf,
    pub additional_directories: Vec<PathBuf>,
    pub prompt: String,
    pub conversation_id: Option<String>,
    pub provider_project_id: Option<String>,
    pub model: Option<String>,
    pub mode: Option<String>,
    pub permission_mode: String,
    pub attachments: Vec<PathBuf>,
    pub on_event: Arc<dyn Fn(ProviderRuntimeEvent) + Send + Sync>,
}

#[derive(Debug, Clone)]
pub enum ProviderRuntimeEvent {
    PermissionRequested { question: String, detail: String },
    InputRequested { input: Value },
    Structured { event: Value },
    TextSnapshot { text: String },
}
#[derive(Debug, Clone)]
pub struct PromptResult {
    pub text: String,
    pub conversation_id: Option<String>,
    pub provider_project_id: Option<String>,
    pub events: Vec<Value>,
    pub diagnostic: Option<String>,
}

#[async_trait]
pub trait AgentProvider: Send + Sync {
    fn id(&self) -> &'static str;
    fn capabilities(&self) -> ProviderCapabilities;
    fn detect(&self) -> Value;
    fn commands(&self) -> Vec<Value>;
    fn models(&self) -> Result<Vec<Value>>;
    fn history(&self) -> Result<Vec<Value>>;
    async fn prompt(&self, request: PromptRequest) -> Result<PromptResult>;
    async fn cancel(&self, session_id: &str) -> Result<()>;
    async fn quota(&self) -> Result<Value>;
}

#[derive(Clone, Default)]
pub struct AgyProvider {
    running: RunningAgents,
    model_cache: Arc<Mutex<Vec<Value>>>,
}

struct RunningAgent {
    killer: Box<dyn ChildKiller + Send + Sync>,
    writer: Box<dyn Write + Send>,
    process_id: Option<u32>,
    conversation_path: Option<PathBuf>,
    pending_permission: Option<Value>,
    pending_input: Option<Value>,
    stopped_tasks: HashSet<String>,
    attention_tasks: HashSet<String>,
    deny_steps: usize,
    permission_denied: bool,
}
type RunningAgentHandle = Arc<Mutex<RunningAgent>>;
type RunningAgents = Arc<Mutex<HashMap<String, RunningAgentHandle>>>;
impl AgyProvider {
    pub fn new() -> Self {
        Self::default()
    }
    fn binary() -> Option<PathBuf> {
        std::env::var_os("AGY_BIN")
            .map(PathBuf::from)
            .filter(|p| p.exists())
            .or_else(|| which("agy"))
            .or_else(|| {
                ["/opt/homebrew/bin/agy", "/usr/local/bin/agy"]
                    .into_iter()
                    .map(PathBuf::from)
                    .find(|path| path.exists())
            })
            .or_else(|| {
                dirs::home_dir()
                    .map(|h| h.join(".local/bin/agy"))
                    .filter(|p| p.exists())
            })
    }
    pub fn import_history(&self, conversation_id: &str) -> Result<Vec<Value>> {
        let path = conversation_file(conversation_id).context("conversation not found")?;
        read_structured_events(&path)
    }
    fn conversation_dirs() -> Vec<PathBuf> {
        let gemini = dirs::home_dir().expect("home").join(".gemini");
        ["antigravity-cli", "antigravity"]
            .into_iter()
            .map(|name| gemini.join(name).join("conversations"))
            .filter(|path| path.exists())
            .collect()
    }

    pub fn pending_permission(&self, session_id: &str) -> Option<Value> {
        let agent = self.running.lock().ok()?.get(session_id)?.clone();
        agent.lock().ok()?.pending_permission.clone()
    }

    pub fn pending_input(&self, session_id: &str) -> Option<Value> {
        let agent = self.running.lock().ok()?.get(session_id)?.clone();
        agent.lock().ok()?.pending_input.clone()
    }

    pub fn steer(&self, session_id: &str, prompt: &str, attachments: &[PathBuf]) -> Result<()> {
        let agent = self
            .running
            .lock()
            .unwrap()
            .get(session_id)
            .cloned()
            .context("no active agent for session")?;
        let mut running_agent = agent.lock().unwrap();
        let conversation = running_agent
            .conversation_path
            .as_deref()
            .context("agy conversation is not ready for steering")?;
        if !conversation_accepts_steer(conversation)? {
            bail!("agy is not waiting while a background task runs")
        }
        let prompt = prompt_with_attachments(prompt.to_owned(), attachments);
        write_interactive_prompt(&mut running_agent.writer, &prompt)
    }

    pub fn stop_task(&self, session_id: &str, task_id: &str) -> Result<(String, String)> {
        let agent = self
            .running
            .lock()
            .unwrap()
            .get(session_id)
            .cloned()
            .context("no active agent for session")?;
        let root_pid = agent
            .lock()
            .unwrap()
            .process_id
            .context("agy process id is unavailable")?;
        let conversation_id = task_id
            .split_once("/task-")
            .map(|(id, _)| id)
            .context("invalid agy task id")?;
        let conversation = conversation_file(conversation_id).context("conversation not found")?;
        let description = background_task_description(&conversation, task_id)?
            .context("background task description not found")?;
        terminate_task_process(root_pid, &description)?;
        let prompt = stopped_task_prompt(task_id, &description);
        let mut running_agent = agent.lock().unwrap();
        running_agent.stopped_tasks.insert(task_id.to_owned());
        write_interactive_prompt(&mut running_agent.writer, &prompt)?;
        Ok((prompt, description))
    }

    pub fn respond_input(&self, session_id: &str, selected_indices: &[usize]) -> Result<()> {
        let agent = self
            .running
            .lock()
            .unwrap()
            .get(session_id)
            .cloned()
            .context("no active input request")?;
        let mut running_agent = agent.lock().unwrap();
        let input = running_agent
            .pending_input
            .take()
            .context("no active input request")?;
        let multi_select = input["multiSelect"].as_bool().unwrap_or(false);
        if multi_select {
            let max = selected_indices.iter().copied().max().unwrap_or_default();
            for index in 0..=max {
                if selected_indices.contains(&index) {
                    running_agent.writer.write_all(b" ")?;
                }
                if index < max {
                    running_agent.writer.write_all(b"\x1b[B")?;
                }
            }
        } else {
            for _ in 0..selected_indices[0] {
                running_agent.writer.write_all(b"\x1b[B")?;
            }
        }
        running_agent.writer.write_all(b"\r")?;
        running_agent.writer.flush()?;
        Ok(())
    }

    pub fn respond_permission(&self, session_id: &str, allow: bool) -> Result<()> {
        let agent = self
            .running
            .lock()
            .unwrap()
            .get(session_id)
            .cloned()
            .context("no active permission request")?;
        let mut running_agent = agent.lock().unwrap();
        if running_agent.pending_permission.take().is_none() {
            bail!("no active permission request");
        }
        if allow {
            running_agent.writer.write_all(b"\r")?;
        } else {
            for _ in 0..running_agent.deny_steps {
                running_agent.writer.write_all(b"\x1b[B")?;
            }
            running_agent.writer.write_all(b"\r")?;
            running_agent.permission_denied = true;
        }
        running_agent.writer.flush()?;
        drop(running_agent);
        if !allow {
            std::thread::spawn(move || {
                std::thread::sleep(Duration::from_millis(750));
                if let Ok(mut running_agent) = agent.lock() {
                    let _ = running_agent.writer.write_all(b"\x03\x03");
                    let _ = running_agent.writer.flush();
                }
            });
        }
        Ok(())
    }
}

#[async_trait]
impl AgentProvider for AgyProvider {
    fn id(&self) -> &'static str {
        "agy"
    }
    fn capabilities(&self) -> ProviderCapabilities {
        ProviderCapabilities {
            steering: true,
            image_input: true,
            image_output: false,
            thinking: true,
            tools: true,
            permissions: true,
            resume: true,
            slash_commands: true,
            quota: true,
        }
    }
    fn detect(&self) -> Value {
        let bin = Self::binary();
        let version = bin
            .as_ref()
            .and_then(|b| Command::new(b).arg("--version").output().ok())
            .filter(|o| o.status.success())
            .map(|o| String::from_utf8_lossy(&o.stdout).trim().to_owned());
        json!({"id":self.id(),"installed":bin.is_some(),"path":bin,"version":version,"capabilities":self.capabilities(),"termsWarning":true})
    }
    fn commands(&self) -> Vec<Value> {
        vec![json!({"name":"/usage","description":"Show quota usage"})]
    }
    fn models(&self) -> Result<Vec<Value>> {
        let binary = Self::binary().context("agy is not installed")?;
        let mut last_error = None;
        for _ in 0..2 {
            match Command::new(&binary).arg("models").output() {
                Ok(output) if output.status.success() => {
                    let models = parse_models(&String::from_utf8_lossy(&output.stdout));
                    if !models.is_empty() {
                        *self.model_cache.lock().unwrap() = models.clone();
                        return Ok(models);
                    }
                    last_error = Some("agy models returned no models".to_owned());
                }
                Ok(output) => {
                    last_error = Some(format!(
                        "agy models failed: {}",
                        String::from_utf8_lossy(&output.stderr).trim()
                    ));
                }
                Err(error) => last_error = Some(format!("cannot run agy models: {error}")),
            }
        }
        let cached = self.model_cache.lock().unwrap().clone();
        if !cached.is_empty() {
            return Ok(cached);
        }
        bail!(last_error.unwrap_or_else(|| "agy models failed".to_owned()))
    }
    fn history(&self) -> Result<Vec<Value>> {
        let mut out = Vec::new();
        let mut seen = std::collections::HashSet::new();
        for dir in Self::conversation_dirs() {
            for e in fs::read_dir(dir)? {
                let e = e?;
                let p = e.path();
                if p.extension().and_then(|x| x.to_str()) != Some("db") {
                    continue;
                }
                let id = p.file_stem().unwrap().to_string_lossy().into_owned();
                if !seen.insert(id.clone()) {
                    continue;
                }
                let modified = e
                    .metadata()?
                    .modified()
                    .ok()
                    .and_then(|t| t.duration_since(SystemTime::UNIX_EPOCH).ok())
                    .map(|d| d.as_secs());
                let summary = read_conversation_summary(&p).unwrap_or_default();
                out.push(json!({"conversationId":id,"path":p,"modifiedAt":modified,"title":summary.title,"cwd":summary.cwd,"compatible":summary.compatible}));
            }
        }
        out.sort_by_key(|v| std::cmp::Reverse(v["modifiedAt"].as_u64().unwrap_or(0)));
        Ok(out)
    }
    async fn prompt(&self, request: PromptRequest) -> Result<PromptResult> {
        let bin = Self::binary().context("agy is not installed")?;
        let before = newest_conversation();
        let project_ids_before = agy_project_ids();
        let playground_before = agy_playground_directories();
        let requested_conversation_id = request.conversation_id.clone();
        let requested_project_id = request.provider_project_id.clone();
        let baseline_step = requested_conversation_id
            .as_deref()
            .and_then(conversation_file)
            .and_then(|path| conversation_max_step(&path).ok())
            .unwrap_or(-1);
        let session_id = request.session_id.clone();
        let running = self.running.clone();
        let prompt = prompt_with_attachments(request.prompt, &request.attachments);
        let completion_prompt = prompt.clone();
        let conversation_before_prompt = before.clone();
        let initial_conversation_path = requested_conversation_id
            .as_deref()
            .and_then(conversation_file);
        let command_project_id = requested_project_id.clone();
        let creating_project = command_project_id.is_none();
        let expected_cwd = request.cwd.clone();
        let result = tokio::task::spawn_blocking(move || {
            let pair = NativePtySystem::default().openpty(PtySize {
                rows: 40,
                cols: 160,
                pixel_width: 0,
                pixel_height: 0,
            })?;
            let mut cmd = CommandBuilder::new(bin);
            if let Some(id) = command_project_id.as_deref() {
                cmd.arg("--project");
                cmd.arg(id);
            } else if request.conversation_id.is_none() {
                cmd.arg("--new-project");
            }
            if let Some(id) = request.conversation_id.as_deref() {
                cmd.arg("--conversation");
                cmd.arg(id);
            }
            if let Some(m) = request.model.as_deref() {
                cmd.arg("--model");
                cmd.arg(m);
            }
            if let Some(m) = request.mode.as_deref() {
                cmd.arg("--mode");
                cmd.arg(m);
            }
            if request.permission_mode == "full" {
                cmd.arg("--dangerously-skip-permissions");
            } else {
                cmd.arg("--sandbox");
            }
            for directory in &request.additional_directories {
                cmd.arg("--add-dir");
                cmd.arg(directory);
            }
            cmd.arg("--prompt-interactive");
            cmd.arg(prompt);
            cmd.cwd(&request.cwd);
            let mut child = pair.slave.spawn_command(cmd)?;
            let process_id = child.process_id();
            drop(pair.slave);
            let writer = pair.master.take_writer()?;
            let agent = Arc::new(Mutex::new(RunningAgent {
                killer: child.clone_killer(),
                writer,
                process_id,
                conversation_path: initial_conversation_path,
                pending_permission: None,
                pending_input: None,
                stopped_tasks: HashSet::new(),
                attention_tasks: HashSet::new(),
                deny_steps: 1,
                permission_denied: false,
            }));
            running
                .lock()
                .unwrap()
                .insert(session_id.clone(), agent.clone());
            let monitor_stop = Arc::new(AtomicBool::new(false));
            let monitor_stopped = monitor_stop.clone();
            let completion_confirmed = Arc::new(AtomicBool::new(false));
            let monitor_completion_confirmed = completion_confirmed.clone();
            let monitor_agent = agent.clone();
            let monitor_conversation_id = request.conversation_id.clone();
            let monitor_events = request.on_event.clone();
            let completion_monitor = std::thread::spawn(move || {
                let mut emitted_events = HashSet::new();
                let mut emitted_text = String::new();
                let mut completion_tracker = TurnCompletionTracker::default();
                while !monitor_stopped.load(Ordering::Relaxed) {
                    let conversation_path = monitor_conversation_id
                        .as_deref()
                        .and_then(conversation_file)
                        .or_else(|| {
                            newest_conversation()
                                .filter(|path| Some(path) != conversation_before_prompt.as_ref())
                        });
                    if let Some(path) = conversation_path {
                        if let Ok(mut running_agent) = monitor_agent.lock() {
                            running_agent.conversation_path = Some(path.clone());
                        }
                        if let Ok(events) = read_structured_events(&path) {
                            for mut event in events.into_iter().filter(|event| {
                                event["index"].as_i64().unwrap_or(-1) > baseline_step
                            }) {
                                if let Ok(running_agent) = monitor_agent.lock() {
                                    apply_stopped_task_status(
                                        &mut event,
                                        &running_agent.stopped_tasks,
                                    );
                                }
                                if let Some((task_id, prompt)) = task_attention_prompt(&event)
                                    && conversation_accepts_steer(&path).unwrap_or(false)
                                    && let Ok(mut running_agent) = monitor_agent.lock()
                                    && running_agent.attention_tasks.insert(task_id)
                                {
                                    let _ = write_interactive_prompt(
                                        &mut running_agent.writer,
                                        &prompt,
                                    );
                                    event["task"]["attentionSent"] = json!(true);
                                }
                                if event["type"] == "text" {
                                    let text = event["text"].as_str().unwrap_or_default();
                                    if !text.is_empty() && text != emitted_text {
                                        emitted_text = text.to_owned();
                                        monitor_events(ProviderRuntimeEvent::TextSnapshot {
                                            text: emitted_text.clone(),
                                        });
                                    }
                                } else if is_runtime_structured_event(&event)
                                    && emitted_events.insert(event.to_string())
                                {
                                    if let Some(input) = question_input(&event) {
                                        if let Ok(mut running_agent) = monitor_agent.lock() {
                                            running_agent.pending_input = Some(input.clone());
                                        }
                                        monitor_events(ProviderRuntimeEvent::InputRequested {
                                            input,
                                        });
                                    }
                                    monitor_events(ProviderRuntimeEvent::Structured { event });
                                }
                            }
                        }
                        let has_stopped_tasks = monitor_agent
                            .lock()
                            .map(|agent| !agent.stopped_tasks.is_empty())
                            .unwrap_or(false);
                        if let Ok(Some(progress)) =
                            conversation_turn_progress(&path, &completion_prompt, baseline_step)
                            && completion_tracker.should_complete(progress, has_stopped_tasks)
                        {
                            monitor_completion_confirmed.store(true, Ordering::Relaxed);
                            if let Ok(mut running_agent) = monitor_agent.lock() {
                                // `--prompt-interactive` stays alive after a final response and
                                // waits for another prompt. Riz owns one agy process per turn, so
                                // explicitly reap it here; the conversation DB is already saved
                                // and the next queued message resumes the same conversation.
                                let _ = running_agent.killer.kill();
                            }
                            break;
                        }
                    }
                    std::thread::sleep(Duration::from_millis(200));
                }
            });
            let mut reader = pair.master.try_clone_reader()?;
            let mut bytes = Vec::new();
            let mut buffer = [0_u8; 8192];
            let mut permission_markers = 0;
            loop {
                let count = reader.read(&mut buffer)?;
                if count == 0 {
                    break;
                }
                bytes.extend_from_slice(&buffer[..count]);
                let plain = strip_ansi(&String::from_utf8_lossy(&bytes));
                let current_permission_markers = plain.matches("1. Yes").count();
                if current_permission_markers > permission_markers
                    && let Some((question, deny_steps)) = permission_prompt(&plain)
                {
                    permission_markers = current_permission_markers;
                    let tool = latest_tool_event(request.conversation_id.as_deref());
                    let detail = tool
                        .as_ref()
                        .and_then(|event| serde_json::to_string_pretty(event).ok())
                        .unwrap_or_else(|| question.clone());
                    if request.permission_mode == "workspace"
                        && tool.as_ref().is_some_and(|event| {
                            workspace_allows(event, &request.cwd, &request.additional_directories)
                        })
                    {
                        let mut agent = agent.lock().unwrap();
                        agent.writer.write_all(b"\r")?;
                        agent.writer.flush()?;
                        continue;
                    }
                    let pending = json!({"question":question,"detail":detail});
                    let mut running_agent = agent.lock().unwrap();
                    running_agent.pending_permission = Some(pending);
                    running_agent.deny_steps = deny_steps;
                    drop(running_agent);
                    (request.on_event)(ProviderRuntimeEvent::PermissionRequested {
                        question,
                        detail,
                    });
                }
            }
            let status = child.wait()?;
            monitor_stop.store(true, Ordering::Relaxed);
            let _ = completion_monitor.join();
            let (permission_denied, stopped_tasks) = {
                let running_agent = agent.lock().unwrap();
                (
                    running_agent.permission_denied,
                    running_agent.stopped_tasks.clone(),
                )
            };
            running.lock().unwrap().remove(&session_id);
            if !status.success() && !completion_confirmed.load(Ordering::Relaxed) {
                bail!(
                    "agy exited with status {status:?}: {}",
                    strip_ansi(&String::from_utf8_lossy(&bytes))
                )
            }
            if !completion_confirmed.load(Ordering::Relaxed) {
                bail!(
                    "agy exited before the turn reached a confirmed terminal state: {}",
                    strip_ansi(&String::from_utf8_lossy(&bytes))
                )
            }
            Ok::<_, anyhow::Error>((
                strip_ansi(&String::from_utf8_lossy(&bytes)),
                permission_denied,
                stopped_tasks,
            ))
        })
        .await??;
        let after = newest_conversation();
        let conversation_id = requested_conversation_id.or_else(|| {
            after
                .filter(|a| Some(a) != before.as_ref())
                .map(|p| p.file_stem().unwrap().to_string_lossy().into_owned())
        });
        let mut events = conversation_id
            .as_deref()
            .and_then(conversation_file)
            .and_then(|path| read_structured_events(&path).ok())
            .unwrap_or_default()
            .into_iter()
            .filter(|event| event["index"].as_i64().unwrap_or(-1) > baseline_step)
            .collect::<Vec<_>>();
        for event in &mut events {
            apply_stopped_task_status(event, &result.2);
        }
        let text = events
            .iter()
            .rev()
            .find(|event| event["type"] == "text")
            .and_then(|event| event["text"].as_str())
            .filter(|text| !text.trim().is_empty())
            .map(str::to_owned)
            .unwrap_or_else(|| {
                if result.1 {
                    "Operation denied by user.".to_owned()
                } else {
                    result.0
                }
            });
        let provider_project_id = requested_project_id.or_else(|| {
            let created = agy_project_ids()
                .difference(&project_ids_before)
                .cloned()
                .collect::<Vec<_>>();
            (created.len() == 1)
                .then(|| created[0].clone())
                .or_else(|| conversation_id.as_deref().and_then(conversation_project_id))
        });
        let new_playgrounds = agy_playground_directories()
            .difference(&playground_before)
            .cloned()
            .collect::<Vec<_>>();
        if !new_playgrounds.is_empty() {
            bail!(
                "agy created an unexpected Antigravity playground: {}",
                new_playgrounds
                    .iter()
                    .map(|path| path.display().to_string())
                    .collect::<Vec<_>>()
                    .join(", ")
            );
        }
        if creating_project {
            let project_id = provider_project_id
                .as_deref()
                .context("agy did not report the project created for this workspace")?;
            validate_agy_project_workspace(project_id, &expected_cwd)?;
        }
        Ok(PromptResult {
            text,
            conversation_id,
            provider_project_id,
            events,
            diagnostic: None,
        })
    }
    async fn cancel(&self, session_id: &str) -> Result<()> {
        let agent = self.running.lock().unwrap().get(session_id).cloned();
        if let Some(agent) = agent {
            agent.lock().unwrap().killer.kill()?;
        }
        Ok(())
    }
    async fn quota(&self) -> Result<Value> {
        tokio::task::spawn_blocking(quota_via_pty).await?
    }
}

fn agy_project_ids() -> HashSet<String> {
    let Some(root) = dirs::home_dir().map(|home| home.join(".gemini/config/projects")) else {
        return HashSet::new();
    };
    fs::read_dir(root)
        .into_iter()
        .flatten()
        .flatten()
        .filter_map(|entry| {
            (entry.path().extension().and_then(|value| value.to_str()) == Some("json"))
                .then(|| {
                    entry
                        .path()
                        .file_stem()
                        .map(|value| value.to_string_lossy().into_owned())
                })
                .flatten()
        })
        .collect()
}

fn agy_playground_directories() -> HashSet<PathBuf> {
    let Some(root) = dirs::home_dir().map(|home| home.join(".gemini/antigravity/playground"))
    else {
        return HashSet::new();
    };
    fs::read_dir(root)
        .into_iter()
        .flatten()
        .flatten()
        .filter_map(|entry| entry.file_type().ok()?.is_dir().then(|| entry.path()))
        .collect()
}

fn validate_agy_project_workspace(project_id: &str, cwd: &Path) -> Result<()> {
    let config_path = dirs::home_dir()
        .context("home directory is unavailable")?
        .join(".gemini/config/projects")
        .join(format!("{project_id}.json"));
    let config: Value =
        serde_json::from_slice(&fs::read(&config_path).with_context(|| {
            format!("cannot read agy project config {}", config_path.display())
        })?)?;
    let actual = config["projectResources"]["resources"]
        .as_array()
        .context("agy project config has no workspace resources")?
        .iter()
        .filter_map(|resource| resource["folderUri"].as_str())
        .map(|uri| {
            Url::parse(uri)
                .with_context(|| format!("invalid agy workspace URI {uri}"))?
                .to_file_path()
                .map_err(|_| anyhow::anyhow!("agy workspace URI is not a file URI: {uri}"))?
                .canonicalize()
                .with_context(|| format!("cannot access agy workspace URI {uri}"))
        })
        .collect::<Result<HashSet<_>>>()?;
    let expected = HashSet::from([cwd
        .canonicalize()
        .with_context(|| format!("cannot access Riz workspace {}", cwd.display()))?]);
    if actual != expected {
        bail!(
            "agy registered a different workspace for project {project_id}: expected {expected:?}, got {actual:?}"
        );
    }
    Ok(())
}

fn conversation_project_id(conversation_id: &str) -> Option<String> {
    let database = dirs::home_dir()?.join(".gemini/antigravity-cli/conversation_summaries.db");
    let connection = Connection::open_with_flags(
        database,
        rusqlite::OpenFlags::SQLITE_OPEN_READ_ONLY | rusqlite::OpenFlags::SQLITE_OPEN_NO_MUTEX,
    )
    .ok()?;
    connection
        .query_row(
            "SELECT project_id FROM conversation_summaries WHERE conversation_id=?1",
            [conversation_id],
            |row| row.get::<_, String>(0),
        )
        .ok()
        .filter(|id| !id.is_empty())
}

fn is_runtime_structured_event(event: &Value) -> bool {
    !matches!(event["type"].as_str(), Some("user" | "text" | "title"))
}

fn parse_models(output: &str) -> Vec<Value> {
    output
        .lines()
        .map(str::trim)
        .filter(|line| !line.is_empty())
        .map(|model| json!({"id": model, "name": model}))
        .collect()
}

#[derive(Default)]
struct ConversationSummary {
    title: Option<String>,
    cwd: Option<String>,
    compatible: bool,
}
fn read_conversation_summary(path: &Path) -> Result<ConversationSummary> {
    let c = Connection::open_with_flags(path, rusqlite::OpenFlags::SQLITE_OPEN_READ_ONLY)?;
    let count: i64 = c.query_row("SELECT count(*) FROM steps", [], |r| r.get(0))?;
    let title = fs::read_to_string(transcript_path(path)?)
        .ok()
        .and_then(|contents| transcript_title(&contents));
    let cwd = c
        .query_row(
            "SELECT data FROM trajectory_metadata_blob ORDER BY id LIMIT 1",
            [],
            |row| row.get::<_, Vec<u8>>(0),
        )
        .ok()
        .and_then(|blob| {
            extract_strings(&blob).into_iter().find_map(|value| {
                let path = value.strip_prefix("file://")?;
                Path::new(path)
                    .is_dir()
                    .then(|| path.trim_end_matches('/').to_owned())
            })
        });
    Ok(ConversationSummary {
        title,
        cwd,
        compatible: count >= 0,
    })
}

fn transcript_title(contents: &str) -> Option<String> {
    let content = contents
        .lines()
        .filter_map(|line| serde_json::from_str::<Value>(line).ok())
        .find(|row| row["source"] == "USER_EXPLICIT" && row["type"] == "USER_INPUT")?["content"]
        .as_str()?
        .to_owned();
    let request = regex::Regex::new(r"(?s)<USER_REQUEST>\s*(.*?)\s*</USER_REQUEST>")
        .ok()?
        .captures(&content)
        .and_then(|capture| capture.get(1))
        .map_or(content.as_str(), |capture| capture.as_str());
    let single_line = request.split_whitespace().collect::<Vec<_>>().join(" ");
    if single_line.is_empty() {
        return None;
    }
    let mut title = single_line.chars().take(80).collect::<String>();
    if single_line.chars().count() > 80 {
        title.push_str("...");
    }
    Some(title)
}
fn read_structured_events(path: &Path) -> Result<Vec<Value>> {
    if let Ok(events) = read_transcript_events(path)
        && !events.is_empty()
    {
        return Ok(events);
    }
    let c = Connection::open_with_flags(path, rusqlite::OpenFlags::SQLITE_OPEN_READ_ONLY)?;
    let mut s = c.prepare(
        "SELECT idx,step_type,status,step_payload FROM steps ORDER BY idx DESC LIMIT 200",
    )?;
    let mut rows = s.query([])?;
    let mut out = Vec::new();
    while let Some(r) = rows.next()? {
        let idx: i64 = r.get(0)?;
        let kind: i64 = r.get(1)?;
        let status: i64 = r.get(2)?;
        let blob: Vec<u8> = r.get(3)?;
        let strings = extract_strings(&blob);
        let event_type = match kind {
            14 => "user",
            15 => "text",
            23 => "title",
            5 => "edit",
            21 => "command",
            127 => "subagent",
            138 => "question",
            _ => "tool",
        };
        if !strings.is_empty() {
            out.push(json!({"index":idx,"type":event_type,"stepType":kind,"status":status,"text":strings.into_iter().max_by_key(String::len)}));
        }
    }
    out.reverse();
    Ok(out)
}

fn read_transcript_events(conversation_path: &Path) -> Result<Vec<Value>> {
    let id = conversation_path
        .file_stem()
        .context("conversation has no id")?;
    let root = conversation_path
        .parent()
        .and_then(Path::parent)
        .context("conversation has no provider root")?;
    let transcript = root
        .join("brain")
        .join(id)
        .join(".system_generated/logs/transcript.jsonl");
    let contents = fs::read_to_string(transcript)?;
    let rows = contents
        .lines()
        .filter(|line| !line.trim().is_empty())
        .map(serde_json::from_str::<Value>)
        .collect::<serde_json::Result<Vec<_>>>()?;
    let task_completions = background_task_completions(&rows);
    let mut events = Vec::new();
    for row in rows {
        let index = row["step_index"].as_i64().unwrap_or_default();
        let original_content = row["content"].as_str().unwrap_or_default();
        let completion = (row["status"] == "RUNNING")
            .then(|| background_task_id(original_content))
            .flatten()
            .and_then(|task_id| task_completions.get(&task_id));
        let status = completion.map_or_else(
            || row["status"].as_str().unwrap_or("UNKNOWN"),
            |completion| completion.status.as_str(),
        );
        if let Some(calls) = row["tool_calls"].as_array() {
            for call in calls {
                let name = call["name"].as_str().unwrap_or("Tool");
                events.push(json!({
                    "index": index,
                    "type": if name == "ask_question" { "question" } else { "tool_call" },
                    "status": status,
                    "name": call["name"],
                    "arguments": call["args"],
                    "text": call["args"]["toolAction"].as_str().or_else(|| call["args"]["toolSummary"].as_str()).unwrap_or_else(|| call["name"].as_str().unwrap_or("Tool")),
                }));
            }
        }
        let content = completion.map_or(original_content, |completion| completion.text.as_str());
        if content.trim().is_empty() {
            continue;
        }
        match (row["source"].as_str(), row["type"].as_str()) {
            (Some(source), Some("USER_INPUT")) if source.starts_with("USER") => {
                events.push(json!({
                    "index": index,
                    "type": "user",
                    "status": status,
                    "text": explicit_user_request(content),
                }));
            }
            (Some("MODEL"), Some("PLANNER_RESPONSE")) => events.push(json!({
                "index": index,
                "type": "text",
                "status": status,
                "text": content,
            })),
            (Some("MODEL"), Some(kind)) if !kind.ends_with("RESPONSE") => {
                let mut event = json!({
                    "index": index,
                    "type": "tool_result",
                    "status": status,
                    "name": kind.to_ascii_lowercase(),
                    "text": content,
                });
                if kind == "RUN_COMMAND"
                    && let Some(task) =
                        background_task_details(conversation_path, original_content, status)
                {
                    event["task"] = task;
                }
                events.push(event);
            }
            _ => {}
        }
    }
    Ok(events)
}

fn explicit_user_request(content: &str) -> &str {
    content
        .split_once("<USER_REQUEST>\n")
        .and_then(|(_, rest)| rest.split_once("\n</USER_REQUEST>"))
        .map_or(content, |(request, _)| request)
}

fn prompt_with_attachments(mut prompt: String, attachments: &[PathBuf]) -> String {
    for attachment in attachments {
        prompt.push('\n');
        prompt.push('@');
        prompt.push_str(&attachment.to_string_lossy());
    }
    prompt
}

fn write_interactive_prompt(writer: &mut dyn Write, prompt: &str) -> Result<()> {
    writer.write_all(b"\x1b[200~")?;
    writer.write_all(prompt.as_bytes())?;
    writer.write_all(b"\x1b[201~\r")?;
    writer.flush()?;
    Ok(())
}

fn stopped_task_prompt(task_id: &str, description: &str) -> String {
    format!(
        "[Riz control message] The user manually stopped background task {task_id} ({description}). Do not automatically retry or restart it. It may have been blocked while waiting for terminal input that was not visible in the task log. Briefly explain the output already available, then wait for the user's next instruction."
    )
}

fn task_attention_prompt(event: &Value) -> Option<(String, String)> {
    let task = event["task"].as_object()?;
    if !task.get("mayBeWaitingForInput")?.as_bool()? {
        return None;
    }
    let task_id = task.get("id")?.as_str()?.to_owned();
    let description = task
        .get("description")
        .and_then(Value::as_str)
        .unwrap_or_default();
    Some((
        task_id.clone(),
        format!(
            "[Riz runtime notice] Background task {task_id} ({description}) has produced no captured output for at least 15 seconds. It may be waiting for interactive terminal input that is not visible in its task log. Inspect the task now. If input is appropriate, use manage_task send_input yourself. Do not blindly restart the task."
        ),
    ))
}

fn question_input(event: &Value) -> Option<Value> {
    if event["type"] != "question" && event["name"] != "ask_question" {
        return None;
    }
    let encoded;
    let questions = if let Some(questions) = event["arguments"]["questions"].as_array() {
        questions
    } else {
        encoded = serde_json::from_str::<Value>(event["arguments"]["questions"].as_str()?).ok()?;
        encoded.as_array()?
    };
    let question = questions.first()?;
    let options = question["options"].as_array()?.clone();
    if options.is_empty() {
        return None;
    }
    Some(json!({
        "question": question["question"].as_str().unwrap_or("Choose an option"),
        "options": options,
        "multiSelect": question["is_multi_select"].as_bool().unwrap_or(false),
    }))
}
fn extract_strings(bytes: &[u8]) -> Vec<String> {
    let mut out = Vec::new();
    let mut i = 0;
    while i < bytes.len() {
        let tag = bytes[i];
        i += 1;
        let wire = tag & 7;
        if wire == 2 {
            let (mut len, mut shift) = (0_usize, 0);
            while i < bytes.len() && shift < 35 {
                let b = bytes[i];
                i += 1;
                len |= ((b & 0x7f) as usize) << shift;
                if b & 0x80 == 0 {
                    break;
                }
                shift += 7
            }
            if i + len <= bytes.len() {
                let part = &bytes[i..i + len];
                if let Ok(s) = std::str::from_utf8(part) {
                    if s.chars()
                        .filter(|c| !c.is_control() || matches!(c, '\n' | '\t'))
                        .count()
                        > 2
                    {
                        out.push(s.to_owned())
                    }
                } else {
                    out.extend(extract_strings(part));
                }
                i += len
            } else {
                break;
            }
        } else {
            match wire {
                0 => {
                    while i < bytes.len() {
                        let b = bytes[i];
                        i += 1;
                        if b & 0x80 == 0 {
                            break;
                        }
                    }
                }
                1 => i = i.saturating_add(8),
                5 => i = i.saturating_add(4),
                _ => break,
            }
        }
    }
    out
}

fn quota_via_pty() -> Result<Value> {
    let bin = AgyProvider::binary().context("agy is not installed")?;
    let pair = NativePtySystem::default().openpty(PtySize {
        rows: 50,
        cols: 140,
        pixel_width: 0,
        pixel_height: 0,
    })?;
    let mut cmd = CommandBuilder::new(bin);
    cmd.arg("--sandbox");
    let mut child = pair.slave.spawn_command(cmd)?;
    drop(pair.slave);
    let mut writer = pair.master.take_writer()?;
    let reader = pair.master.try_clone_reader()?;
    let reader_thread = std::thread::spawn(move || {
        let mut bytes = Vec::with_capacity(512 * 1024);
        let _ = reader.take(2 * 1024 * 1024).read_to_end(&mut bytes);
        bytes
    });
    // A fresh working directory can show the trust gate before commands are
    // accepted. Its first option is the explicit "trust this folder" choice.
    std::thread::sleep(Duration::from_secs(3));
    writer.write_all(b"\r")?;
    writer.flush()?;
    std::thread::sleep(Duration::from_secs(3));
    writer.write_all(b"/usage\r")?;
    writer.flush()?;
    std::thread::sleep(Duration::from_secs(8));
    writer.write_all(&[3, 3])?;
    writer.flush()?;
    std::thread::sleep(Duration::from_millis(250));
    let _ = child.kill();
    let _ = child.wait();
    drop(writer);
    drop(pair.master);
    let bytes = reader_thread
        .join()
        .map_err(|_| anyhow::anyhow!("agy quota reader thread panicked"))?;
    if let Some(path) = std::env::var_os("RIZ_AGY_QUOTA_CAPTURE")
        && let Err(error) = fs::write(&path, &bytes)
    {
        tracing::warn!(?path, %error, "failed to save agy quota diagnostic capture");
    }
    let text = String::from_utf8_lossy(&bytes);
    parse_agy_quota_screen(&text)
}

fn parse_agy_quota_screen(text: &str) -> Result<Value> {
    let text = strip_ansi(text);
    if !text.contains("Models & Quota") {
        bail!("agy /usage did not open the Models & Quota panel")
    }
    let remaining = regex::Regex::new(r"(?i)(\d+(?:\.\d+)?)%\s+remaining")?;
    let mut group: Option<String> = None;
    let mut window: Option<String> = None;
    let mut models = Vec::<Value>::new();

    for raw_line in text.lines() {
        let line = raw_line.trim();
        let refresh_in = line
            .find("Refreshes in ")
            .map(|index| line[index + "Refreshes in ".len()..].trim());
        if line.ends_with(" MODELS")
            && line
                .chars()
                .all(|character| !character.is_alphabetic() || character.is_uppercase())
        {
            group = Some(line.to_owned());
            window = None;
            continue;
        }
        if line.ends_with(" Limit") {
            window = Some(line.to_owned());
            continue;
        }
        let percentage = remaining
            .captures(line)
            .and_then(|capture| capture[1].parse::<f64>().ok())
            .or_else(|| {
                line.eq_ignore_ascii_case("Quota available")
                    .then_some(100.0)
            });
        if let Some(percentage) = percentage
            && let (Some(group), Some(window)) = (&group, &window)
        {
            let model_id = format!("{group} · {window}");
            if let Some(existing) = models.iter_mut().find(|model| model["modelId"] == model_id) {
                existing["remainingPercentage"] = json!(percentage);
            } else {
                models.push(json!({
                    "modelId": model_id,
                    "remainingPercentage": percentage,
                }));
            }
            if let Some(refresh_in) = refresh_in
                && let Some(last) = models.last_mut()
            {
                last["refreshIn"] = json!(refresh_in);
            }
            continue;
        }
        if let Some(refresh_in) = refresh_in
            && let Some(last) = models.last_mut()
        {
            last["refreshIn"] = json!(refresh_in);
        }
    }

    let mut percentages = models
        .iter()
        .filter_map(|model| model["remainingPercentage"].as_f64())
        .collect::<Vec<_>>();
    if percentages.is_empty() {
        percentages = quota_percentages(&text)?;
        models = percentages
            .iter()
            .enumerate()
            .map(|(index, percentage)| {
                json!({
                    "modelId": format!("Quota {}", index + 1),
                    "remainingPercentage": percentage,
                })
            })
            .collect();
    }
    if percentages.is_empty() {
        bail!("agy Models & Quota panel contained no recognizable limits")
    }
    Ok(json!({
        "source": "agy-pty",
        "models": models,
        "remainingPercentages": percentages,
        "fetchedAt": chrono::Utc::now(),
    }))
}

fn quota_percentages(text: &str) -> Result<Vec<f64>> {
    let suffix = regex::Regex::new(r"(?i)(\d+(?:\.\d+)?)%\s+(?:remaining|left)")?;
    let prefix = regex::Regex::new(r"(?i)(?:remaining|left)\s*:?\s*(\d+(?:\.\d+)?)%")?;
    let mut values = suffix
        .captures_iter(text)
        .chain(prefix.captures_iter(text))
        .filter_map(|capture| capture[1].parse::<f64>().ok())
        .collect::<Vec<_>>();
    values.sort_by(f64::total_cmp);
    values.dedup();
    Ok(values)
}
fn newest_conversation() -> Option<PathBuf> {
    AgyProvider::conversation_dirs()
        .into_iter()
        .filter_map(|dir| fs::read_dir(dir).ok())
        .flatten()
        .filter_map(Result::ok)
        .filter(|e| e.path().extension().and_then(|x| x.to_str()) == Some("db"))
        .max_by_key(|e| e.metadata().and_then(|m| m.modified()).ok())
        .map(|e| e.path())
}

fn conversation_file(id: &str) -> Option<PathBuf> {
    AgyProvider::conversation_dirs()
        .into_iter()
        .map(|dir| dir.join(format!("{id}.db")))
        .find(|path| path.exists())
}

fn conversation_max_step(path: &Path) -> Result<i64> {
    let transcript = transcript_path(path)?;
    let contents = fs::read_to_string(transcript)?;
    Ok(contents
        .lines()
        .filter_map(|line| serde_json::from_str::<Value>(line).ok())
        .filter_map(|row| row["step_index"].as_i64())
        .max()
        .unwrap_or(-1))
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
struct ConversationTurnProgress {
    final_response_step: Option<i64>,
    latest_planner_step: Option<i64>,
    has_active_work: bool,
}

#[derive(Debug, Clone)]
struct BackgroundTaskCompletion {
    status: String,
    text: String,
}

fn background_task_id(content: &str) -> Option<String> {
    regex::Regex::new(r"[0-9a-fA-F-]{36}/task-[0-9]+")
        .ok()?
        .find(content)
        .map(|matched| matched.as_str().to_owned())
}

fn background_task_details(conversation_path: &Path, content: &str, status: &str) -> Option<Value> {
    let task_id = background_task_id(content)?;
    let description = content
        .lines()
        .find_map(|line| line.strip_prefix("Task Description: "))
        .unwrap_or_default();
    let started_at = content
        .lines()
        .find_map(|line| line.strip_prefix("Created At: "));
    let log_uri = content
        .lines()
        .find_map(|line| line.strip_prefix("Task logs are available at: "));
    let log_path = log_uri
        .and_then(|uri| Url::parse(uri).ok())
        .and_then(|uri| uri.to_file_path().ok())
        .or_else(|| {
            let name = task_id.rsplit('/').next()?;
            transcript_path(conversation_path)
                .ok()?
                .parent()?
                .parent()?
                .join("tasks")
                .join(format!("{name}.log"))
                .into()
        });
    let log_tail = log_path.as_deref().and_then(read_task_log_tail);
    let may_be_waiting_for_input = status == "RUNNING"
        && task_quiet_duration(log_path.as_deref(), started_at)
            .is_some_and(|duration| duration >= Duration::from_secs(15));
    Some(json!({
        "id": task_id,
        "description": description,
        "startedAt": started_at,
        "status": status,
        "logPath": log_path,
        "logTail": log_tail,
        "mayBeWaitingForInput": may_be_waiting_for_input,
        "supportsInput": true,
    }))
}

fn task_quiet_duration(log_path: Option<&Path>, started_at: Option<&str>) -> Option<Duration> {
    let modified = log_path
        .and_then(|path| path.metadata().ok())
        .and_then(|metadata| metadata.modified().ok())
        .or_else(|| {
            started_at
                .and_then(|value| chrono::DateTime::parse_from_rfc3339(value).ok())
                .and_then(|value| {
                    let seconds = value.timestamp();
                    (seconds >= 0)
                        .then(|| SystemTime::UNIX_EPOCH + Duration::from_secs(seconds as u64))
                })
        })?;
    SystemTime::now().duration_since(modified).ok()
}

fn read_task_log_tail(path: &Path) -> Option<String> {
    const MAX_TASK_LOG_BYTES: usize = 32 * 1024;
    let bytes = fs::read(path).ok()?;
    let start = bytes.len().saturating_sub(MAX_TASK_LOG_BYTES);
    Some(String::from_utf8_lossy(&bytes[start..]).into_owned())
}

fn apply_stopped_task_status(event: &mut Value, stopped_tasks: &HashSet<String>) {
    let Some(task_id) = event["task"]["id"].as_str() else {
        return;
    };
    if stopped_tasks.contains(task_id) {
        event["status"] = json!("CANCELLED");
        event["task"]["status"] = json!("CANCELLED");
    }
}

fn background_task_description(conversation_path: &Path, task_id: &str) -> Result<Option<String>> {
    let contents = fs::read_to_string(transcript_path(conversation_path)?)?;
    Ok(contents
        .lines()
        .filter_map(|line| serde_json::from_str::<Value>(line).ok())
        .filter_map(|row| row["content"].as_str().map(str::to_owned))
        .find(|content| background_task_id(content).as_deref() == Some(task_id))
        .and_then(|content| {
            content
                .lines()
                .find_map(|line| line.strip_prefix("Task Description: "))
                .map(str::to_owned)
        }))
}

fn terminate_task_process(root_pid: u32, description: &str) -> Result<()> {
    #[cfg(unix)]
    {
        let output = Command::new("ps")
            .args(["-axo", "pid=,ppid=,pgid=,stat=,command=", "-ww"])
            .output()
            .context("inspect agy task processes")?;
        let rows = String::from_utf8_lossy(&output.stdout)
            .lines()
            .filter_map(|line| {
                let mut fields = line.split_whitespace();
                let pid = fields.next()?.parse::<u32>().ok()?;
                let parent = fields.next()?.parse::<u32>().ok()?;
                let pgid = fields.next()?.parse::<i32>().ok()?;
                let status = fields.next()?.to_owned();
                let command = fields.collect::<Vec<_>>().join(" ");
                Some((pid, parent, pgid, status, command))
            })
            .collect::<Vec<_>>();
        let mut descendants = HashSet::from([root_pid]);
        loop {
            let before = descendants.len();
            for (pid, parent, _, _, _) in &rows {
                if descendants.contains(parent) {
                    descendants.insert(*pid);
                }
            }
            if descendants.len() == before {
                break;
            }
        }
        let groups = rows
            .iter()
            .filter(|(pid, _, pgid, _, command)| {
                *pid != root_pid
                    && *pgid > 0
                    && descendants.contains(pid)
                    && command.contains(description)
            })
            .map(|(_, _, pgid, _, _)| *pgid)
            .collect::<HashSet<_>>();
        if groups.is_empty() {
            bail!("agy task process is no longer running")
        }
        for pgid in groups {
            let group = Pid::from_raw(pgid);
            killpg(group, Signal::SIGTERM)?;
            let _ = killpg(group, Signal::SIGCONT);
        }
        Ok(())
    }
    #[cfg(not(unix))]
    {
        let _ = (root_pid, description);
        bail!("stopping agy background tasks is unsupported on this platform")
    }
}

fn background_task_completions(rows: &[Value]) -> HashMap<String, BackgroundTaskCompletion> {
    rows.iter()
        .filter(|row| row["source"] == "SYSTEM" && row["type"] == "SYSTEM_MESSAGE")
        .filter_map(|row| {
            let content = row["content"].as_str()?;
            let cancelled = content.contains("was canceled with result");
            if !content.contains("finished with result") && !cancelled {
                return None;
            }
            let task_id = background_task_id(content)?;
            let nonzero_exit = regex::Regex::new(r"exited with code\s+([1-9][0-9]*)")
                .ok()
                .is_some_and(|pattern| pattern.is_match(content));
            Some((
                task_id,
                BackgroundTaskCompletion {
                    status: if cancelled {
                        "CANCELLED"
                    } else if nonzero_exit {
                        "ERROR"
                    } else {
                        "DONE"
                    }
                    .to_owned(),
                    text: content.to_owned(),
                },
            ))
        })
        .collect()
}

fn conversation_accepts_steer(path: &Path) -> Result<bool> {
    let contents = fs::read_to_string(transcript_path(path)?)?;
    let rows = contents
        .lines()
        .filter_map(|line| serde_json::from_str::<Value>(line).ok())
        .collect::<Vec<_>>();
    let completions = background_task_completions(&rows);
    let active_task_step = rows
        .iter()
        .filter(|row| {
            row["source"] == "MODEL"
                && row["status"] == "RUNNING"
                && row["content"]
                    .as_str()
                    .and_then(background_task_id)
                    .is_some_and(|task_id| !completions.contains_key(&task_id))
        })
        .filter_map(|row| row["step_index"].as_i64())
        .max();
    let Some(active_task_step) = active_task_step else {
        return Ok(false);
    };
    Ok(rows.iter().any(|row| {
        row["step_index"].as_i64().unwrap_or(-1) > active_task_step
            && row["source"] == "MODEL"
            && row["type"] == "PLANNER_RESPONSE"
            && row["status"] == "DONE"
            && row["content"]
                .as_str()
                .is_some_and(|content| !content.trim().is_empty())
    }))
}

#[derive(Debug, Default)]
struct TurnCompletionTracker {
    planner_seen_while_working: Option<i64>,
}

impl TurnCompletionTracker {
    fn should_complete(
        &mut self,
        progress: ConversationTurnProgress,
        allow_empty_terminal_response: bool,
    ) -> bool {
        if progress.has_active_work {
            if let Some(step) = progress.latest_planner_step {
                self.planner_seen_while_working = Some(
                    self.planner_seen_while_working
                        .map_or(step, |current| current.max(step)),
                );
            }
            return false;
        }
        let terminal_step = if allow_empty_terminal_response {
            progress.latest_planner_step
        } else {
            progress.final_response_step
        };
        terminal_step.is_some_and(|step| {
            self.planner_seen_while_working
                .is_none_or(|floor| step > floor)
        })
    }
}

fn conversation_turn_progress(
    path: &Path,
    prompt: &str,
    baseline_step: i64,
) -> Result<Option<ConversationTurnProgress>> {
    let contents = fs::read_to_string(transcript_path(path)?)?;
    let rows = contents
        .lines()
        .filter_map(|line| serde_json::from_str::<Value>(line).ok())
        .collect::<Vec<_>>();
    let user_step = rows
        .iter()
        .filter(|row| row["step_index"].as_i64().unwrap_or(-1) > baseline_step)
        .filter(|row| row["source"] == "USER_EXPLICIT" && row["type"] == "USER_INPUT")
        .filter(|row| {
            row["content"]
                .as_str()
                .is_some_and(|content| content.contains(prompt.trim()))
        })
        .filter_map(|row| row["step_index"].as_i64())
        .max();
    let Some(user_step) = user_step else {
        return Ok(None);
    };
    let mut latest_steps = HashMap::<i64, &Value>::new();
    for row in &rows {
        let step = row["step_index"].as_i64().unwrap_or(-1);
        if step > user_step {
            latest_steps.insert(step, row);
        }
    }
    let final_response_step = latest_steps
        .iter()
        .filter(|(_, row)| {
            row["source"] == "MODEL"
                && row["type"] == "PLANNER_RESPONSE"
                && row["status"] == "DONE"
                && row["content"]
                    .as_str()
                    .is_some_and(|content| !content.trim().is_empty())
        })
        .map(|(step, _)| *step)
        .max();
    let latest_planner_step = latest_steps
        .iter()
        .filter(|(_, row)| {
            row["source"] == "MODEL" && row["type"] == "PLANNER_RESPONSE" && row["status"] == "DONE"
        })
        .map(|(step, _)| *step)
        .max();
    let task_completions = background_task_completions(&rows);
    let has_active_work = latest_steps.values().any(|row| {
        row["source"] == "MODEL"
            && row["type"] != "PLANNER_RESPONSE"
            && row["status"] == "RUNNING"
            && row["content"]
                .as_str()
                .and_then(background_task_id)
                .is_none_or(|task_id| !task_completions.contains_key(&task_id))
    });
    Ok(Some(ConversationTurnProgress {
        final_response_step,
        latest_planner_step,
        has_active_work,
    }))
}

fn transcript_path(conversation_path: &Path) -> Result<PathBuf> {
    let id = conversation_path
        .file_stem()
        .context("conversation has no id")?;
    let root = conversation_path
        .parent()
        .and_then(Path::parent)
        .context("conversation has no provider root")?;
    Ok(root
        .join("brain")
        .join(id)
        .join(".system_generated/logs/transcript.jsonl"))
}

fn latest_tool_event(conversation_id: Option<&str>) -> Option<Value> {
    let path = conversation_id
        .and_then(conversation_file)
        .or_else(newest_conversation)?;
    let events = read_transcript_events(&path).ok()?;
    events
        .into_iter()
        .rev()
        .find(|event| event["type"] == "tool_call")
}

fn workspace_allows(event: &Value, cwd: &Path, additional_directories: &[PathBuf]) -> bool {
    let name = event["name"]
        .as_str()
        .unwrap_or_default()
        .to_ascii_lowercase();
    let safe_file_tool = matches!(
        name.as_str(),
        "write_to_file"
            | "replace_file_content"
            | "multi_replace_file_content"
            | "create_file"
            | "edit_file"
            | "apply_patch"
    );
    if !safe_file_tool {
        return false;
    }
    let Some(arguments) = event["arguments"].as_object() else {
        return false;
    };
    let paths = arguments
        .iter()
        .filter(|(key, _)| {
            matches!(
                key.to_ascii_lowercase().as_str(),
                "targetfile" | "filepath" | "path"
            )
        })
        .filter_map(|(_, value)| value.as_str())
        .collect::<Vec<_>>();
    !paths.is_empty()
        && paths.into_iter().all(|path| {
            path_is_within_workspace(path, cwd)
                || additional_directories
                    .iter()
                    .any(|root| path_is_within_workspace(path, root))
        })
}

fn path_is_within_workspace(raw: &str, cwd: &Path) -> bool {
    let raw = raw.trim().trim_matches('"');
    let candidate = PathBuf::from(raw);
    let candidate = if candidate.is_absolute() {
        candidate
    } else {
        cwd.join(candidate)
    };
    let Ok(root) = cwd.canonicalize() else {
        return false;
    };
    let mut ancestor = candidate.as_path();
    while !ancestor.exists() {
        let Some(parent) = ancestor.parent() else {
            return false;
        };
        ancestor = parent;
    }
    ancestor
        .canonicalize()
        .is_ok_and(|resolved| resolved.starts_with(root))
}
fn which(name: &str) -> Option<PathBuf> {
    let o = Command::new("/usr/bin/which").arg(name).output().ok()?;
    (o.status.success()).then(|| PathBuf::from(String::from_utf8_lossy(&o.stdout).trim()))
}
fn strip_ansi(s: &str) -> String {
    regex::Regex::new(r"\x1b\[[0-?]*[ -/]*[@-~]")
        .unwrap()
        .replace_all(s, "")
        .replace('\r', "")
}

fn permission_prompt(output: &str) -> Option<(String, usize)> {
    let marker = output.rfind("1. Yes")?;
    let question = output[..marker]
        .lines()
        .rev()
        .map(str::trim)
        .find(|line| line.ends_with('?'))
        .map(str::to_owned)?;
    let no = regex::Regex::new(r"(?m)^\s*(\d+)\.\s+No\b")
        .ok()?
        .captures(&output[marker..])?;
    let choice = no[1].parse::<usize>().ok()?;
    Some((question, choice.saturating_sub(1)))
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn extracts_nested_utf8() {
        let data = [0x0a, 0x05, b'h', b'e', b'l', b'l', b'o'];
        assert!(extract_strings(&data).contains(&"hello".into()));
    }

    #[test]
    fn extracts_explicit_request_from_transcript_metadata() {
        assert_eq!(
            explicit_user_request(
                "<USER_REQUEST>\nRun the task\n</USER_REQUEST>\n<ADDITIONAL_METADATA>ignored"
            ),
            "Run the task"
        );
    }

    #[test]
    fn extracts_permission_question() {
        let output = "Create file\nAllow creation of this file?\n> 1. Yes, allow creation\n  2. No, deny creation";
        assert_eq!(
            permission_prompt(output),
            Some(("Allow creation of this file?".to_owned(), 1))
        );
    }

    #[test]
    fn extracts_interactive_question() {
        let event = json!({
            "type": "question",
            "name": "ask_question",
            "arguments": {"questions": [{
                "question": "Choose one",
                "options": ["A", "B"],
                "is_multi_select": false
            }]}
        });
        assert_eq!(
            question_input(&event),
            Some(json!({"question":"Choose one","options":["A","B"],"multiSelect":false}))
        );

        let transcript_event = json!({
            "type": "question",
            "name": "ask_question",
            "arguments": {
                "questions": "[{\"question\":\"Choose one\",\"options\":[\"A\",\"B\"],\"is_multi_select\":false}]"
            }
        });
        assert_eq!(question_input(&transcript_event), question_input(&event));
    }

    #[test]
    fn streams_only_structured_runtime_events() {
        assert!(is_runtime_structured_event(&json!({"type":"tool_call"})));
        assert!(is_runtime_structured_event(&json!({"type":"thinking"})));
        assert!(!is_runtime_structured_event(&json!({"type":"user"})));
        assert!(!is_runtime_structured_event(&json!({"type":"text"})));
        assert!(!is_runtime_structured_event(&json!({"type":"title"})));
    }

    #[test]
    fn parses_models_reported_by_agy() {
        assert_eq!(
            parse_models("gemini-3.6-flash-high\n\nclaude-sonnet-4-6\n"),
            vec![
                json!({"id":"gemini-3.6-flash-high","name":"gemini-3.6-flash-high"}),
                json!({"id":"claude-sonnet-4-6","name":"claude-sonnet-4-6"}),
            ]
        );
    }

    #[test]
    fn extracts_terminal_permission_denial_position() {
        let output =
            "Do you want to proceed?\n> 1. Yes\n  2. Yes, always\n  3. Yes, persist\n  4. No";
        assert_eq!(
            permission_prompt(output),
            Some(("Do you want to proceed?".to_owned(), 3))
        );
    }

    #[test]
    fn quota_parser_rejects_trust_prompts_and_accepts_common_labels() {
        assert!(
            quota_percentages("Do you trust the contents of this project?")
                .unwrap()
                .is_empty()
        );
        assert_eq!(
            quota_percentages("Pro 72% remaining; Flash remaining: 41.5%").unwrap(),
            vec![41.5, 72.0]
        );
    }

    #[test]
    fn parses_agy_models_and_quota_panel() {
        let quota = parse_agy_quota_screen(
            r#"
Models & Quota
GEMINI MODELS
Models within this group: Gemini Flash, Gemini Pro
Weekly Limit
53% remaining · terminal cursor residue Refreshes in 37h 24m
Five Hour Limit
96% remaining
Refreshes in 1h 13m
CLAUDE AND GPT MODELS
Models within this group: Claude Opus, Claude Sonnet, GPT-OSS
Weekly Limit
32% remaining
Refreshes in 121h 35m
Five Hour Limit
100.00%
Quota available
"#,
        )
        .unwrap();
        assert_eq!(quota["source"], "agy-pty");
        assert_eq!(
            quota["remainingPercentages"],
            json!([53.0, 96.0, 32.0, 100.0])
        );
        assert_eq!(
            quota["models"][0]["modelId"],
            "GEMINI MODELS · Weekly Limit"
        );
        assert_eq!(quota["models"][0]["refreshIn"], "37h 24m");
        assert_eq!(
            quota["models"][3]["modelId"],
            "CLAUDE AND GPT MODELS · Five Hour Limit"
        );
    }

    #[test]
    fn history_title_uses_the_first_explicit_user_request() {
        let transcript = r#"{"source":"USER_EXPLICIT","type":"USER_INPUT","content":"<USER_REQUEST>\nBuild the Riz client\nwith tests\n</USER_REQUEST>\n<ADDITIONAL_METADATA>ignore me</ADDITIONAL_METADATA>"}"#;
        assert_eq!(
            transcript_title(transcript).as_deref(),
            Some("Build the Riz client with tests")
        );
    }

    #[test]
    fn transcript_completion_requires_a_new_finished_turn() {
        let temp = tempfile::tempdir().unwrap();
        let provider_root = temp.path().join("antigravity-cli");
        let conversation = provider_root.join("conversations/test.db");
        let transcript = provider_root.join("brain/test/.system_generated/logs/transcript.jsonl");
        fs::create_dir_all(conversation.parent().unwrap()).unwrap();
        fs::create_dir_all(transcript.parent().unwrap()).unwrap();
        fs::write(&conversation, []).unwrap();
        fs::write(
            &transcript,
            concat!(
                "{\"step_index\":5,\"source\":\"USER_EXPLICIT\",\"type\":\"USER_INPUT\",\"status\":\"DONE\",\"content\":\"new prompt\"}\n",
                "{\"step_index\":6,\"source\":\"MODEL\",\"type\":\"PLANNER_RESPONSE\",\"status\":\"DONE\",\"content\":\"finished\"}\n"
            ),
        )
        .unwrap();
        assert_eq!(
            conversation_turn_progress(&conversation, "new prompt", 4).unwrap(),
            Some(ConversationTurnProgress {
                final_response_step: Some(6),
                latest_planner_step: Some(6),
                has_active_work: false,
            })
        );
        assert!(
            conversation_turn_progress(&conversation, "new prompt", 5)
                .unwrap()
                .is_none()
        );
    }

    #[test]
    fn running_background_work_requires_a_later_final_response() {
        let temp = tempfile::tempdir().unwrap();
        let provider_root = temp.path().join("antigravity-cli");
        let conversation = provider_root.join("conversations/test.db");
        let transcript = provider_root.join("brain/test/.system_generated/logs/transcript.jsonl");
        fs::create_dir_all(conversation.parent().unwrap()).unwrap();
        fs::create_dir_all(transcript.parent().unwrap()).unwrap();
        fs::write(&conversation, []).unwrap();
        fs::write(
            &transcript,
            concat!(
                "{\"step_index\":5,\"source\":\"USER_EXPLICIT\",\"type\":\"USER_INPUT\",\"status\":\"DONE\",\"content\":\"clone repositories\"}\n",
                "{\"step_index\":6,\"source\":\"MODEL\",\"type\":\"RUN_COMMAND\",\"status\":\"RUNNING\",\"content\":\"Tool is running with task id: 00000000-0000-0000-0000-000000000006/task-6\"}\n",
                "{\"step_index\":7,\"source\":\"MODEL\",\"type\":\"PLANNER_RESPONSE\",\"status\":\"DONE\",\"content\":\"running in background\"}\n"
            ),
        )
        .unwrap();
        let mut tracker = TurnCompletionTracker::default();
        let running = conversation_turn_progress(&conversation, "clone repositories", 4)
            .unwrap()
            .unwrap();
        assert!(running.has_active_work);
        assert!(!tracker.should_complete(running, false));

        fs::write(
            &transcript,
            concat!(
                "{\"step_index\":5,\"source\":\"USER_EXPLICIT\",\"type\":\"USER_INPUT\",\"status\":\"DONE\",\"content\":\"clone repositories\"}\n",
                "{\"step_index\":6,\"source\":\"MODEL\",\"type\":\"RUN_COMMAND\",\"status\":\"RUNNING\",\"content\":\"Tool is running with task id: 00000000-0000-0000-0000-000000000006/task-6\"}\n",
                "{\"step_index\":7,\"source\":\"MODEL\",\"type\":\"PLANNER_RESPONSE\",\"status\":\"DONE\",\"content\":\"running in background\"}\n",
                "{\"step_index\":8,\"source\":\"SYSTEM\",\"type\":\"SYSTEM_MESSAGE\",\"status\":\"DONE\",\"content\":\"Task id \\\"00000000-0000-0000-0000-000000000006/task-6\\\" finished with result: The command exited with code 0.\"}\n"
            ),
        )
        .unwrap();
        let old_response = conversation_turn_progress(&conversation, "clone repositories", 4)
            .unwrap()
            .unwrap();
        assert!(!old_response.has_active_work);
        assert!(!tracker.should_complete(old_response, false));

        fs::write(
            &transcript,
            concat!(
                "{\"step_index\":5,\"source\":\"USER_EXPLICIT\",\"type\":\"USER_INPUT\",\"status\":\"DONE\",\"content\":\"clone repositories\"}\n",
                "{\"step_index\":6,\"source\":\"MODEL\",\"type\":\"RUN_COMMAND\",\"status\":\"RUNNING\",\"content\":\"Tool is running with task id: 00000000-0000-0000-0000-000000000006/task-6\"}\n",
                "{\"step_index\":7,\"source\":\"MODEL\",\"type\":\"PLANNER_RESPONSE\",\"status\":\"DONE\",\"content\":\"running in background\"}\n",
                "{\"step_index\":8,\"source\":\"SYSTEM\",\"type\":\"SYSTEM_MESSAGE\",\"status\":\"DONE\",\"content\":\"Task id \\\"00000000-0000-0000-0000-000000000006/task-6\\\" finished with result: The command exited with code 0.\"}\n",
                "{\"step_index\":9,\"source\":\"MODEL\",\"type\":\"PLANNER_RESPONSE\",\"status\":\"DONE\",\"content\":\"all repositories cloned\"}\n"
            ),
        )
        .unwrap();
        let final_response = conversation_turn_progress(&conversation, "clone repositories", 4)
            .unwrap()
            .unwrap();
        assert!(tracker.should_complete(final_response, false));
        let events = read_structured_events(&conversation).unwrap();
        let task = events
            .iter()
            .find(|event| event["index"] == 6 && event["type"] == "tool_result")
            .unwrap();
        assert_eq!(task["status"], "DONE");
        assert!(
            task["text"]
                .as_str()
                .unwrap()
                .contains("exited with code 0")
        );
    }

    #[test]
    fn manually_stopped_task_accepts_agys_empty_terminal_response() {
        let mut tracker = TurnCompletionTracker::default();
        assert!(!tracker.should_complete(
            ConversationTurnProgress {
                final_response_step: Some(5),
                latest_planner_step: Some(5),
                has_active_work: true,
            },
            false,
        ));
        assert!(tracker.should_complete(
            ConversationTurnProgress {
                final_response_step: Some(5),
                latest_planner_step: Some(7),
                has_active_work: false,
            },
            true,
        ));
    }

    #[test]
    fn background_task_event_includes_live_log_details() {
        let temp = tempfile::tempdir().unwrap();
        let provider_root = temp.path().join("antigravity-cli");
        let conversation = provider_root.join("conversations/test.db");
        let system_root = provider_root.join("brain/test/.system_generated");
        let transcript = system_root.join("logs/transcript.jsonl");
        let task_log = system_root.join("tasks/task-3.log");
        fs::create_dir_all(conversation.parent().unwrap()).unwrap();
        fs::create_dir_all(transcript.parent().unwrap()).unwrap();
        fs::create_dir_all(task_log.parent().unwrap()).unwrap();
        fs::write(&conversation, []).unwrap();
        fs::write(&task_log, "cloning one\ncloning two\n").unwrap();
        fs::write(
            &transcript,
            "{\"step_index\":3,\"source\":\"MODEL\",\"type\":\"RUN_COMMAND\",\"status\":\"RUNNING\",\"content\":\"Tool is running with task id: 00000000-0000-0000-0000-000000000003/task-3\\nTask Description: git clone repositories\\nCreated At: 2026-07-30T00:00:00Z\"}\n",
        )
        .unwrap();

        let events = read_structured_events(&conversation).unwrap();
        let task = &events[0]["task"];
        assert_eq!(task["id"], "00000000-0000-0000-0000-000000000003/task-3");
        assert_eq!(task["description"], "git clone repositories");
        assert_eq!(task["status"], "RUNNING");
        assert_eq!(task["logTail"], "cloning one\ncloning two\n");
        assert_eq!(task["supportsInput"], true);

        fs::write(&task_log, "cloning one\ncloning two\ndone\n").unwrap();
        let updated = read_structured_events(&conversation).unwrap();
        assert_eq!(
            updated[0]["task"]["logTail"],
            "cloning one\ncloning two\ndone\n"
        );
        let mut stopped = updated[0].clone();
        apply_stopped_task_status(
            &mut stopped,
            &HashSet::from(["00000000-0000-0000-0000-000000000003/task-3".to_owned()]),
        );
        assert_eq!(stopped["status"], "CANCELLED");
        assert_eq!(stopped["task"]["status"], "CANCELLED");

        assert!(!conversation_accepts_steer(&conversation).unwrap());
        fs::write(
            &transcript,
            concat!(
                "{\"step_index\":3,\"source\":\"MODEL\",\"type\":\"RUN_COMMAND\",\"status\":\"RUNNING\",\"content\":\"Tool is running with task id: 00000000-0000-0000-0000-000000000003/task-3\\nTask Description: git clone repositories\"}\n",
                "{\"step_index\":4,\"source\":\"MODEL\",\"type\":\"PLANNER_RESPONSE\",\"status\":\"DONE\",\"content\":\"waiting for clone\"}\n"
            ),
        )
        .unwrap();
        assert!(conversation_accepts_steer(&conversation).unwrap());
        let mut transcript_file = fs::OpenOptions::new()
            .append(true)
            .open(&transcript)
            .unwrap();
        writeln!(
            transcript_file,
            "{}",
            json!({
                "step_index": 5,
                "source": "SYSTEM",
                "type": "SYSTEM_MESSAGE",
                "status": "DONE",
                "content": "Task id \\\"00000000-0000-0000-0000-000000000003/task-3\\\" was canceled with result: context canceled by manage_task"
            })
        )
        .unwrap();
        assert!(!conversation_accepts_steer(&conversation).unwrap());
        let cancelled = read_structured_events(&conversation).unwrap();
        assert_eq!(cancelled[0]["task"]["status"], "CANCELLED");
        assert_eq!(
            cancelled
                .iter()
                .filter(|event| !event["task"].is_null())
                .count(),
            1
        );
    }

    #[test]
    fn interactive_prompt_uses_bracketed_paste_and_includes_attachments() {
        let prompt = prompt_with_attachments(
            "redirect the task".to_owned(),
            &[PathBuf::from("/tmp/reference.png")],
        );
        let mut bytes = Vec::new();
        write_interactive_prompt(&mut bytes, &prompt).unwrap();
        assert_eq!(
            bytes,
            b"\x1b[200~redirect the task\n@/tmp/reference.png\x1b[201~\r"
        );

        let stopped = stopped_task_prompt("conversation/task-3", "git clone private-repo");
        assert!(stopped.contains("user manually stopped"));
        assert!(stopped.contains("Do not automatically retry"));
        assert!(stopped.contains("terminal input"));
        let attention = task_attention_prompt(&json!({
            "task": {
                "id": "conversation/task-3",
                "description": "interactive command",
                "mayBeWaitingForInput": true,
            }
        }))
        .unwrap();
        assert_eq!(attention.0, "conversation/task-3");
        assert!(attention.1.contains("manage_task send_input yourself"));
    }

    #[cfg(unix)]
    #[test]
    fn stopping_task_terminates_only_the_matching_background_process_group() {
        let pair = NativePtySystem::default()
            .openpty(PtySize {
                rows: 24,
                cols: 80,
                pixel_width: 0,
                pixel_height: 0,
            })
            .unwrap();
        let mut command = CommandBuilder::new("/bin/sh");
        command.args(["-c", "set -m; sleep 60 & while :; do sleep 1; done"]);
        let mut child = pair.slave.spawn_command(command).unwrap();
        let root_pid = child.process_id().unwrap();
        std::thread::sleep(Duration::from_millis(150));

        let task_pid = Command::new("pgrep")
            .args(["-P", &root_pid.to_string(), "-f", "sleep 60"])
            .output()
            .unwrap();
        let task_pid = String::from_utf8_lossy(&task_pid.stdout)
            .lines()
            .next()
            .unwrap()
            .parse::<i32>()
            .unwrap();

        terminate_task_process(root_pid, "sleep 60").unwrap();

        let deadline = std::time::Instant::now() + Duration::from_secs(3);
        let stopped = loop {
            if nix::sys::signal::kill(Pid::from_raw(task_pid), None).is_err() {
                break true;
            }
            if std::time::Instant::now() >= deadline {
                break false;
            }
            std::thread::sleep(Duration::from_millis(25));
        };
        assert!(
            nix::sys::signal::kill(Pid::from_raw(root_pid as i32), None).is_ok(),
            "agy root process was terminated with the background task"
        );
        child.kill().unwrap();
        assert!(stopped, "background task did not stop");
    }

    #[test]
    fn transcript_progress_uses_latest_step_status_and_ignores_old_turns() {
        let temp = tempfile::tempdir().unwrap();
        let provider_root = temp.path().join("antigravity-cli");
        let conversation = provider_root.join("conversations/test.db");
        let transcript = provider_root.join("brain/test/.system_generated/logs/transcript.jsonl");
        fs::create_dir_all(conversation.parent().unwrap()).unwrap();
        fs::create_dir_all(transcript.parent().unwrap()).unwrap();
        fs::write(&conversation, []).unwrap();
        fs::write(
            &transcript,
            concat!(
                "{\"step_index\":1,\"source\":\"MODEL\",\"type\":\"RUN_COMMAND\",\"status\":\"RUNNING\",\"content\":\"old task\"}\n",
                "{\"step_index\":5,\"source\":\"USER_EXPLICIT\",\"type\":\"USER_INPUT\",\"status\":\"DONE\",\"content\":\"new prompt\"}\n",
                "{\"step_index\":6,\"source\":\"MODEL\",\"type\":\"RUN_COMMAND\",\"status\":\"RUNNING\",\"content\":\"new task\"}\n",
                "{\"step_index\":6,\"source\":\"MODEL\",\"type\":\"RUN_COMMAND\",\"status\":\"ERROR\",\"content\":\"failed\"}\n",
                "{\"step_index\":7,\"source\":\"MODEL\",\"type\":\"PLANNER_RESPONSE\",\"status\":\"DONE\",\"content\":\"reported failure\"}\n"
            ),
        )
        .unwrap();
        let progress = conversation_turn_progress(&conversation, "new prompt", 4)
            .unwrap()
            .unwrap();
        assert_eq!(progress.final_response_step, Some(7));
        assert!(!progress.has_active_work);
    }

    #[test]
    fn workspace_mode_only_allows_project_file_edits() {
        let temp = tempfile::tempdir().unwrap();
        let additional = tempfile::tempdir().unwrap();
        let inside = temp.path().join("new.txt");
        let edit = json!({
            "name": "write_to_file",
            "arguments": {"TargetFile": inside.to_string_lossy()}
        });
        assert!(workspace_allows(
            &edit,
            temp.path(),
            &[additional.path().to_owned()]
        ));

        let additional_edit = json!({
            "name": "write_to_file",
            "arguments": {"TargetFile": additional.path().join("new.txt").to_string_lossy()}
        });
        assert!(workspace_allows(
            &additional_edit,
            temp.path(),
            &[additional.path().to_owned()]
        ));

        let outside = json!({
            "name": "write_to_file",
            "arguments": {"TargetFile": "/tmp/riz-outside.txt"}
        });
        assert!(!workspace_allows(
            &outside,
            temp.path(),
            &[additional.path().to_owned()]
        ));

        let terminal = json!({
            "name": "run_command",
            "arguments": {"path": inside.to_string_lossy()}
        });
        assert!(!workspace_allows(
            &terminal,
            temp.path(),
            &[additional.path().to_owned()]
        ));
    }
}
