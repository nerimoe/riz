use crate::{db::Database, state::Outbound};
use anyhow::{Context, Result, bail};
use portable_pty::{Child, CommandBuilder, MasterPty, NativePtySystem, PtySize, PtySystem};
use riz_protocol::{BinaryChannel, encode_binary};
use serde_json::{Value, json};
use std::{
    collections::{HashMap, VecDeque},
    io::{Read, Write},
    path::{Path, PathBuf},
    sync::{
        Arc, Mutex,
        atomic::{AtomicBool, Ordering},
    },
};
use tokio::sync::broadcast;
use uuid::Uuid;

const BUFFER_LIMIT: usize = 2 * 1024 * 1024;

struct Entry {
    cwd: PathBuf,
    writer: Arc<Mutex<Box<dyn Write + Send>>>,
    master: Arc<Mutex<Box<dyn MasterPty + Send>>>,
    child: Arc<Mutex<Box<dyn Child + Send + Sync>>>,
    buffer: Arc<Mutex<VecDeque<u8>>>,
    closing: Arc<AtomicBool>,
}

#[derive(Clone)]
pub struct TerminalManager {
    entries: Arc<Mutex<HashMap<Uuid, Entry>>>,
    outbound: broadcast::Sender<Outbound>,
    db: Database,
}

impl TerminalManager {
    pub fn new(outbound: broadcast::Sender<Outbound>, db: Database) -> Self {
        Self {
            entries: Arc::new(Mutex::new(HashMap::new())),
            outbound,
            db,
        }
    }
    pub fn create(
        &self,
        project_id: Option<Uuid>,
        cwd: &Path,
        cols: u16,
        rows: u16,
    ) -> Result<Value> {
        if !cwd.is_dir() {
            bail!("terminal cwd is not a directory")
        }
        let pair = NativePtySystem::default().openpty(PtySize {
            rows,
            cols,
            pixel_width: 0,
            pixel_height: 0,
        })?;
        let shell = std::env::var("SHELL").unwrap_or_else(|_| "/bin/zsh".into());
        let mut cmd = CommandBuilder::new(shell);
        cmd.cwd(cwd);
        cmd.arg("-l");
        cmd.env("TERM", "xterm-256color");
        let child = pair.slave.spawn_command(cmd)?;
        drop(pair.slave);
        let mut reader = pair.master.try_clone_reader()?;
        let writer = pair.master.take_writer()?;
        let id = Uuid::new_v4();
        let buffer = Arc::new(Mutex::new(VecDeque::new()));
        let reader_buffer = buffer.clone();
        let closing = Arc::new(AtomicBool::new(false));
        let reader_closing = closing.clone();
        let tx = self.outbound.clone();
        let db = self.db.clone();
        db.record_terminal(id, project_id, cwd)?;
        std::thread::Builder::new()
            .name(format!("riz-terminal-{id}"))
            .spawn(move || {
                let mut chunk = [0_u8; 8192];
                while let Ok(n) = reader.read(&mut chunk) {
                    if n == 0 {
                        break;
                    }
                    {
                        let mut b = reader_buffer.lock().unwrap();
                        b.extend(&chunk[..n]);
                        while b.len() > BUFFER_LIMIT {
                            b.pop_front();
                        }
                    }
                    let _ = tx.send(Outbound::Binary(encode_binary(
                        BinaryChannel::Terminal,
                        id,
                        &chunk[..n],
                    )));
                }
                let status = if reader_closing.load(Ordering::SeqCst) {
                    "cancelled"
                } else {
                    "completed"
                };
                let _ = db.set_terminal_status(id, status);
            })?;
        self.entries.lock().unwrap().insert(
            id,
            Entry {
                cwd: cwd.to_path_buf(),
                writer: Arc::new(Mutex::new(writer)),
                master: Arc::new(Mutex::new(pair.master)),
                child: Arc::new(Mutex::new(child)),
                buffer,
                closing,
            },
        );
        Ok(json!({"id":id,"projectId":project_id,"cwd":cwd,"cols":cols,"rows":rows}))
    }
    pub fn list(&self, cwd: Option<&Path>) -> Value {
        let entries = self.entries.lock().unwrap();
        let mut terminals = entries
            .iter()
            .filter(|(_, entry)| cwd.is_none_or(|cwd| entry.cwd == cwd))
            .map(|(id, entry)| json!({"id":id,"cwd":entry.cwd,"status":"running"}))
            .collect::<Vec<_>>();
        terminals.sort_by(|a, b| a["id"].as_str().cmp(&b["id"].as_str()));
        json!({"terminals":terminals})
    }
    pub fn input(&self, id: Uuid, data: &[u8]) -> Result<()> {
        let entries = self.entries.lock().unwrap();
        let e = entries.get(&id).context("terminal not found")?;
        e.writer.lock().unwrap().write_all(data)?;
        e.writer.lock().unwrap().flush()?;
        Ok(())
    }
    pub fn resize(&self, id: Uuid, cols: u16, rows: u16) -> Result<()> {
        let entries = self.entries.lock().unwrap();
        let e = entries.get(&id).context("terminal not found")?;
        e.master.lock().unwrap().resize(PtySize {
            rows,
            cols,
            pixel_width: 0,
            pixel_height: 0,
        })?;
        Ok(())
    }
    pub fn replay(&self, id: Uuid) -> Result<Vec<u8>> {
        let entries = self.entries.lock().unwrap();
        let e = entries.get(&id).context("terminal not found")?;
        let bytes = e.buffer.lock().unwrap().iter().copied().collect();
        Ok(bytes)
    }
    pub fn close(&self, id: Uuid) -> Result<()> {
        let e = self
            .entries
            .lock()
            .unwrap()
            .remove(&id)
            .context("terminal not found")?;
        e.closing.store(true, Ordering::SeqCst);
        e.child.lock().unwrap().kill()?;
        self.db.set_terminal_status(id, "cancelled")?;
        Ok(())
    }
}
