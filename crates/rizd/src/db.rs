use anyhow::{Context, Result, bail};
use chrono::Utc;
use rusqlite::{Connection, OptionalExtension, params};
use serde::Serialize;
use serde_json::{Value, json};
use std::{
    collections::HashMap,
    path::{Path, PathBuf},
    sync::{Arc, Mutex},
};
use uuid::Uuid;

#[derive(Clone)]
pub struct Database {
    conn: Arc<Mutex<Connection>>,
    projects_root: PathBuf,
}

const RUNTIME_AGENTS_MD: &str = r#"# Riz Runtime Directory

This directory is managed by Riz for runtime files, temporary files, and generated artifacts.

It is not an existing user project or source repository.
"#;

#[derive(Debug, Clone, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct Event {
    pub seq: i64,
    pub topic: String,
    pub payload: Value,
    pub created_at: String,
}

impl Database {
    pub fn open(path: &Path) -> Result<Self> {
        if let Some(parent) = path.parent() {
            std::fs::create_dir_all(parent)?;
        }
        let mut conn = Connection::open(path)?;
        conn.pragma_update(None, "journal_mode", "WAL")?;
        conn.pragma_update(None, "foreign_keys", "ON")?;
        initialize_schema(&conn)?;
        conn.execute(
            "CREATE UNIQUE INDEX IF NOT EXISTS turns_message_id ON turns(message_id) WHERE message_id IS NOT NULL",
            [],
        )?;
        conn.execute("UPDATE turns SET status='interrupted', updated_at=?1 WHERE status IN ('queued','running','waiting_permission','waiting_input')", [now()])?;
        conn.execute("UPDATE sessions SET status='interrupted', updated_at=?1 WHERE status IN ('running','waiting_permission','waiting_input')", [now()])?;
        conn.execute(
            "UPDATE messages SET status='interrupted', updated_at=?1 WHERE status='running'",
            [now()],
        )?;
        conn.execute(
            "UPDATE terminal_metadata SET status='interrupted',updated_at=?1 WHERE status='running'",
            [now()],
        )?;
        let reconciled = reconcile_false_completed_background_tasks(&mut conn)?;
        if reconciled > 0 {
            tracing::warn!(
                sessions = reconciled,
                "corrected completed sessions with unresolved background tasks"
            );
        }
        let projects_root = path
            .parent()
            .unwrap_or_else(|| Path::new("."))
            .join("projects");
        Ok(Self {
            conn: Arc::new(Mutex::new(conn)),
            projects_root,
        })
    }

    fn conn(&self) -> std::sync::MutexGuard<'_, Connection> {
        self.conn.lock().expect("database mutex")
    }

    pub fn snapshot(&self) -> Result<Value> {
        Ok(json!({
            "projects": self.projects()?,
            "sessions": self.sessions(None, true)?,
            "turns": self.turns(None)?,
            "skillSources": self.skill_sources()?,
            "quota": self.latest_quota()?,
            "lastSeq": self.last_seq()?,
        }))
    }

    pub fn append_event(&self, topic: &str, payload: Value) -> Result<Event> {
        let created_at = now();
        let conn = self.conn();
        conn.execute(
            "INSERT INTO events(topic,payload,created_at) VALUES(?1,?2,?3)",
            params![topic, payload.to_string(), created_at],
        )?;
        let seq = conn.last_insert_rowid();
        conn.execute(
            "DELETE FROM events WHERE seq <= (SELECT COALESCE(MAX(seq),0)-10000 FROM events)",
            [],
        )?;
        Ok(Event {
            seq,
            topic: topic.into(),
            payload,
            created_at,
        })
    }

    pub fn events_after(&self, seq: i64, limit: i64) -> Result<Vec<Event>> {
        let conn = self.conn();
        let mut stmt = conn.prepare(
            "SELECT seq,topic,payload,created_at FROM events WHERE seq>?1 ORDER BY seq LIMIT ?2",
        )?;
        let rows = stmt.query_map(params![seq, limit], |r| {
            Ok(Event {
                seq: r.get(0)?,
                topic: r.get(1)?,
                payload: serde_json::from_str::<Value>(&r.get::<_, String>(2)?)
                    .unwrap_or(Value::Null),
                created_at: r.get(3)?,
            })
        })?;
        Ok(rows.collect::<rusqlite::Result<Vec<_>>>()?)
    }

    pub fn last_seq(&self) -> Result<i64> {
        Ok(self
            .conn()
            .query_row("SELECT COALESCE(MAX(seq),0) FROM events", [], |r| r.get(0))?)
    }

    pub fn create_project(&self, display_name: Option<&str>, paths: &[PathBuf]) -> Result<Value> {
        let name = display_name
            .filter(|s| !s.trim().is_empty())
            .map(str::to_owned);
        let id = Uuid::new_v4().to_string();
        let timestamp = now();
        ensure_runtime_directory(&self.project_runtime(&id))?;
        let mut canonical_paths = Vec::with_capacity(paths.len());
        for path in paths {
            let canonical = canonical_directory(path)?;
            if !canonical_paths.contains(&canonical) {
                canonical_paths.push(canonical);
            }
        }
        let mut conn = self.conn();
        let tx = conn.transaction()?;
        tx.execute(
            "INSERT INTO projects(id,custom_name,created_at,updated_at) VALUES(?1,?2,?3,?3)",
            params![id, name, timestamp],
        )?;
        for (position, path) in canonical_paths.iter().enumerate() {
            tx.execute(
                "INSERT INTO project_folders(id,project_id,path,position,created_at) VALUES(?1,?2,?3,?4,?5)",
                params![Uuid::new_v4().to_string(), id, path, position as i64, timestamp],
            )?;
        }
        tx.commit()?;
        drop(conn);
        self.project(&id)?.context("created project missing")
    }

    pub fn rename_project(&self, id: &str, name: Option<&str>) -> Result<Value> {
        let name = name.filter(|value| !value.trim().is_empty());
        let changed = self.conn().execute(
            "UPDATE projects SET custom_name=?2,updated_at=?3 WHERE id=?1",
            params![id, name, now()],
        )?;
        if changed == 0 {
            bail!("project not found");
        }
        self.project(id)?.context("updated project missing")
    }

    pub fn add_project_folder(&self, project_id: &str, path: &Path) -> Result<Value> {
        if self.project(project_id)?.is_none() {
            bail!("project not found");
        }
        let path = canonical_directory(path)?;
        let mut conn = self.conn();
        let tx = conn.transaction()?;
        let position: i64 = tx.query_row(
            "SELECT COALESCE(MAX(position)+1,0) FROM project_folders WHERE project_id=?1",
            [project_id],
            |row| row.get(0),
        )?;
        tx.execute(
            "INSERT INTO project_folders(id,project_id,path,position,created_at) VALUES(?1,?2,?3,?4,?5)",
            params![Uuid::new_v4().to_string(), project_id, path, position, now()],
        )?;
        tx.execute(
            "UPDATE projects SET updated_at=?2 WHERE id=?1",
            params![project_id, now()],
        )?;
        tx.commit()?;
        drop(conn);
        self.project(project_id)?.context("updated project missing")
    }

    pub fn remove_project_folder(&self, project_id: &str, folder_id: &str) -> Result<Value> {
        let mut conn = self.conn();
        let tx = conn.transaction()?;
        let changed = tx.execute(
            "DELETE FROM project_folders WHERE id=?1 AND project_id=?2",
            params![folder_id, project_id],
        )?;
        if changed == 0 {
            bail!("project folder not found");
        }
        tx.execute(
            "UPDATE projects SET updated_at=?2 WHERE id=?1",
            params![project_id, now()],
        )?;
        tx.commit()?;
        drop(conn);
        self.project(project_id)?.context("updated project missing")
    }

    pub fn remove_project(&self, id: &str, mode: &str) -> Result<Value> {
        if !matches!(mode, "detach_sessions" | "delete_sessions") {
            bail!("invalid project removal mode");
        }
        let sessions = self.sessions(Some(id), true)?;
        if self.project(id)?.is_none() {
            bail!("project not found");
        }
        let session_workspaces = if mode == "delete_sessions" {
            sessions
                .iter()
                .map(|session| self.managed_session_workspace(session))
                .collect::<Result<Vec<_>>>()?
        } else {
            Vec::new()
        };
        let timestamp = now();
        let mut conn = self.conn();
        let tx = conn.transaction()?;
        if mode == "detach_sessions" {
            tx.execute(
                "UPDATE session_provider_conversations SET status='superseded',ended_at=?2,end_reason='project_removed' WHERE session_id IN (SELECT id FROM sessions WHERE project_id=?1) AND status='active'",
                params![id, timestamp],
            )?;
            tx.execute(
                "DELETE FROM provider_bindings WHERE scope_type='session' AND scope_id IN (SELECT id FROM sessions WHERE project_id=?1)",
                [id],
            )?;
            tx.execute(
                "UPDATE sessions SET project_id=NULL,external_id=NULL,updated_at=?2 WHERE project_id=?1",
                params![id, timestamp],
            )?;
        } else {
            tx.execute("DELETE FROM sessions WHERE project_id=?1", [id])?;
        }
        tx.execute(
            "DELETE FROM provider_bindings WHERE scope_type='project' AND scope_id=?1",
            [id],
        )?;
        tx.execute("DELETE FROM terminal_metadata WHERE project_id=?1", [id])?;
        tx.execute("DELETE FROM projects WHERE id=?1", [id])?;
        tx.commit()?;
        drop(conn);

        remove_managed_directory(&self.projects_root.join(id))?;
        let deleted_session_ids = if mode == "delete_sessions" {
            for workspace in session_workspaces {
                remove_managed_directory(&workspace)?;
            }
            sessions
                .iter()
                .filter_map(|session| session["id"].as_str().map(str::to_owned))
                .collect::<Vec<_>>()
        } else {
            Vec::new()
        };
        let detached_sessions = if mode == "detach_sessions" {
            sessions
                .iter()
                .filter_map(|session| session["id"].as_str())
                .map(|session_id| {
                    self.session(session_id)?
                        .context("detached session missing")
                })
                .collect::<Result<Vec<_>>>()?
        } else {
            Vec::new()
        };
        Ok(json!({
            "detachedSessions": detached_sessions,
            "deletedSessionIds": deleted_session_ids,
        }))
    }

    pub fn project(&self, id: &str) -> Result<Option<Value>> {
        let conn = self.conn();
        let project = conn
            .query_row(
                "SELECT id,custom_name,created_at,updated_at FROM projects WHERE id=?1",
                [id],
                row_project_base,
            )
            .optional()?;
        project
            .map(|project| hydrate_project(&conn, project, &self.projects_root))
            .transpose()
    }

    pub fn projects(&self) -> Result<Vec<Value>> {
        let conn = self.conn();
        let bases = {
            let mut statement = conn.prepare(
                "SELECT id,custom_name,created_at,updated_at FROM projects ORDER BY COALESCE(custom_name,'') COLLATE NOCASE,created_at",
            )?;
            statement
                .query_map([], row_project_base)?
                .collect::<rusqlite::Result<Vec<_>>>()?
        };
        bases
            .into_iter()
            .map(|project| hydrate_project(&conn, project, &self.projects_root))
            .collect()
    }

    pub fn create_session(
        &self,
        project_id: Option<&str>,
        title: Option<&str>,
        provider: &str,
        external_id: Option<&str>,
        session_root: &Path,
    ) -> Result<Value> {
        self.create_session_with_permission(
            project_id,
            title,
            provider,
            external_id,
            "workspace",
            session_root,
        )
    }

    pub fn create_session_with_permission(
        &self,
        project_id: Option<&str>,
        title: Option<&str>,
        provider: &str,
        external_id: Option<&str>,
        permission_mode: &str,
        session_root: &Path,
    ) -> Result<Value> {
        self.create_session_with_details(
            project_id,
            title,
            provider,
            external_id,
            permission_mode,
            None,
            session_root,
        )
    }

    #[allow(clippy::too_many_arguments)]
    pub fn create_session_with_details(
        &self,
        project_id: Option<&str>,
        title: Option<&str>,
        provider: &str,
        external_id: Option<&str>,
        permission_mode: &str,
        model: Option<&str>,
        session_root: &Path,
    ) -> Result<Value> {
        if let Some(project_id) = project_id
            && self.project(project_id)?.is_none()
        {
            bail!("project not found");
        }
        if !matches!(permission_mode, "ask" | "workspace" | "full") {
            bail!("invalid permission mode");
        }
        let id = Uuid::new_v4().to_string();
        let timestamp = now();
        let title = title.unwrap_or("New session");
        let workspace_path = session_root.join(&id).to_string_lossy().into_owned();
        ensure_runtime_directory(&Path::new(&workspace_path).join("runtime"))?;
        std::fs::create_dir_all(Path::new(&workspace_path).join("attachments"))?;
        std::fs::create_dir_all(Path::new(&workspace_path).join("artifacts"))?;
        self.conn().execute(
            "INSERT INTO sessions(id,project_id,provider,external_id,workspace_path,title,status,created_at,updated_at,permission_mode,model) VALUES(?1,?2,?3,NULL,?4,?5,'completed',?6,?6,?7,?8)",
            params![id, project_id, provider, workspace_path, title, timestamp, permission_mode, model],
        )?;
        if let Some(external_id) = external_id {
            let context = self.execution_context(&id)?;
            self.set_external_id(
                &id,
                external_id,
                None,
                Path::new(context["cwd"].as_str().context("session cwd missing")?),
                &context["additionalDirectories"],
            )?;
        }
        self.session(&id)?.context("created session missing")
    }

    pub fn set_session_model(&self, id: &str, model: Option<&str>) -> Result<Value> {
        let changed = self.conn().execute(
            "UPDATE sessions SET model=?2,updated_at=?3 WHERE id=?1",
            params![id, model, now()],
        )?;
        if changed == 0 {
            bail!("session not found");
        }
        self.session(id)?.context("session not found")
    }

    pub fn session(&self, id: &str) -> Result<Option<Value>> {
        self.conn()
            .query_row(
                "SELECT id,project_id,provider,external_id,workspace_path,title,status,archived_at,created_at,updated_at,permission_mode,model FROM sessions WHERE id=?1",
                [id],
                row_session,
            )
            .optional()
            .map_err(Into::into)
    }

    pub fn sessions(&self, project_id: Option<&str>, include_archived: bool) -> Result<Vec<Value>> {
        let conn = self.conn();
        let sql = "SELECT id,project_id,provider,external_id,workspace_path,title,status,archived_at,created_at,updated_at,permission_mode,model FROM sessions WHERE (?1 IS NULL OR project_id=?1) AND (?2=1 OR archived_at IS NULL) ORDER BY updated_at DESC";
        let mut s = conn.prepare(sql)?;
        Ok(
            s.query_map(params![project_id, include_archived], row_session)?
                .collect::<rusqlite::Result<Vec<_>>>()?,
        )
    }

    pub fn move_session(&self, id: &str, project_id: Option<&str>) -> Result<Value> {
        if let Some(project_id) = project_id
            && self.project(project_id)?.is_none()
        {
            bail!("project not found");
        }
        let session = self.session(id)?.context("session not found")?;
        if matches!(
            session["status"].as_str(),
            Some("queued" | "running" | "waiting_permission" | "waiting_input")
        ) {
            bail!("cannot move a session while a turn is active");
        }
        if session["projectId"].as_str() == project_id {
            return Ok(session);
        }
        let mut conn = self.conn();
        let tx = conn.transaction()?;
        tx.execute(
            "UPDATE session_provider_conversations SET status='superseded',ended_at=?2,end_reason='session_moved' WHERE session_id=?1 AND status='active'",
            params![id, now()],
        )?;
        tx.execute(
            "UPDATE sessions SET project_id=?2,external_id=NULL,updated_at=?3 WHERE id=?1",
            params![id, project_id, now()],
        )?;
        tx.execute(
            "DELETE FROM provider_bindings WHERE scope_type='session' AND scope_id=?1",
            [id],
        )?;
        tx.commit()?;
        drop(conn);
        self.session(id)?.context("updated session missing")
    }

    pub fn delete_session(&self, id: &str) -> Result<()> {
        let session = self.session(id)?.context("session not found")?;
        let workspace = self.managed_session_workspace(&session)?;
        let mut conn = self.conn();
        let tx = conn.transaction()?;
        tx.execute(
            "DELETE FROM provider_bindings WHERE scope_type='session' AND scope_id=?1",
            [id],
        )?;
        tx.execute("DELETE FROM sessions WHERE id=?1", [id])?;
        tx.commit()?;
        drop(conn);
        remove_managed_directory(&workspace)
    }

    fn managed_session_workspace(&self, session: &Value) -> Result<PathBuf> {
        let session_id = session["id"].as_str().context("session id missing")?;
        let workspace = PathBuf::from(
            session["workspacePath"]
                .as_str()
                .context("session workspace missing")?,
        );
        let expected = self
            .projects_root
            .parent()
            .unwrap_or_else(|| Path::new("."))
            .join("sessions")
            .join(session_id);
        if workspace != expected {
            bail!("refusing to remove unmanaged session workspace");
        }
        Ok(workspace)
    }

    pub fn execution_context(&self, session_id: &str) -> Result<Value> {
        let session = self.session(session_id)?.context("session not found")?;
        let (cwd, additional) = if let Some(project_id) = session["projectId"].as_str() {
            let runtime = self.project_runtime(project_id);
            ensure_runtime_directory(&runtime)?;
            let project = self.project(project_id)?.context("project not found")?;
            let folders = project["folders"].as_array().cloned().unwrap_or_default();
            let additional = folders
                .iter()
                .filter_map(|folder| folder["path"].as_str().map(str::to_owned))
                .collect::<Vec<_>>();
            (runtime, additional)
        } else {
            let runtime = Path::new(
                session["workspacePath"]
                    .as_str()
                    .context("session workspace missing")?,
            )
            .join("runtime");
            ensure_runtime_directory(&runtime)?;
            (runtime, Vec::new())
        };
        Ok(json!({"cwd":cwd,"additionalDirectories":additional}))
    }

    fn project_runtime(&self, project_id: &str) -> PathBuf {
        self.projects_root.join(project_id).join("runtime")
    }

    pub fn provider_binding(
        &self,
        provider: &str,
        scope_type: &str,
        scope_id: &str,
    ) -> Result<Option<String>> {
        self.conn()
            .query_row(
                "SELECT external_id FROM provider_bindings WHERE provider=?1 AND scope_type=?2 AND scope_id=?3",
                params![provider, scope_type, scope_id],
                |row| row.get(0),
            )
            .optional()
            .map_err(Into::into)
    }

    pub fn set_provider_binding(
        &self,
        provider: &str,
        scope_type: &str,
        scope_id: &str,
        external_id: &str,
    ) -> Result<()> {
        self.conn().execute(
            "INSERT INTO provider_bindings(provider,scope_type,scope_id,external_id,updated_at) VALUES(?1,?2,?3,?4,?5) ON CONFLICT(provider,scope_type,scope_id) DO UPDATE SET external_id=excluded.external_id,updated_at=excluded.updated_at",
            params![provider, scope_type, scope_id, external_id, now()],
        )?;
        Ok(())
    }

    pub fn archive_session(&self, id: &str, archive: bool) -> Result<()> {
        let ts = if archive { Some(now()) } else { None };
        self.conn().execute(
            "UPDATE sessions SET archived_at=?2,updated_at=?3 WHERE id=?1",
            params![id, ts, now()],
        )?;
        Ok(())
    }
    pub fn set_session_status(&self, id: &str, status: &str) -> Result<()> {
        self.conn().execute(
            "UPDATE sessions SET status=?2,updated_at=?3 WHERE id=?1",
            params![id, status, now()],
        )?;
        Ok(())
    }
    pub fn set_external_id(
        &self,
        id: &str,
        external_id: &str,
        provider_workspace_id: Option<&str>,
        cwd: &Path,
        additional_directories: &Value,
    ) -> Result<()> {
        let mut conn = self.conn();
        let tx = conn.transaction()?;
        let provider = tx
            .query_row("SELECT provider FROM sessions WHERE id=?1", [id], |row| {
                row.get::<_, String>(0)
            })
            .optional()?
            .context("session not found")?;
        let timestamp = now();
        tx.execute(
            "UPDATE session_provider_conversations SET status='superseded',ended_at=?3,end_reason='provider_conversation_replaced' WHERE session_id=?1 AND provider=?2 AND status='active' AND external_id<>?4",
            params![id, provider, timestamp, external_id],
        )?;
        tx.execute(
            "INSERT INTO session_provider_conversations(id,session_id,provider,external_id,provider_workspace_id,cwd_snapshot,additional_directories_snapshot,status,created_at,ended_at,end_reason) VALUES(?1,?2,?3,?4,?5,?6,?7,'active',?8,NULL,NULL) ON CONFLICT(session_id,provider,external_id) DO UPDATE SET provider_workspace_id=excluded.provider_workspace_id,cwd_snapshot=excluded.cwd_snapshot,additional_directories_snapshot=excluded.additional_directories_snapshot,status='active',ended_at=NULL,end_reason=NULL",
            params![Uuid::new_v4().to_string(), id, provider, external_id, provider_workspace_id, cwd.to_string_lossy().as_ref(), additional_directories.to_string(), timestamp],
        )?;
        tx.execute(
            "UPDATE sessions SET external_id=?2,updated_at=?3 WHERE id=?1",
            params![id, external_id, timestamp],
        )?;
        tx.commit()?;
        Ok(())
    }

    pub fn provider_conversations(&self, session_id: &str) -> Result<Vec<Value>> {
        let conn = self.conn();
        let mut statement = conn.prepare(
            "SELECT id,session_id,provider,external_id,provider_workspace_id,cwd_snapshot,additional_directories_snapshot,status,created_at,ended_at,end_reason FROM session_provider_conversations WHERE session_id=?1 ORDER BY created_at,id",
        )?;
        Ok(statement
            .query_map([session_id], row_provider_conversation)?
            .collect::<rusqlite::Result<Vec<_>>>()?)
    }

    pub fn set_session_title(&self, id: &str, title: &str) -> Result<()> {
        self.conn().execute(
            "UPDATE sessions SET title=?2,updated_at=?3 WHERE id=?1",
            params![id, title, now()],
        )?;
        Ok(())
    }

    pub fn set_permission_mode(&self, id: &str, mode: &str) -> Result<()> {
        if !matches!(mode, "ask" | "workspace" | "full") {
            bail!("invalid permission mode");
        }
        let changed = self.conn().execute(
            "UPDATE sessions SET permission_mode=?2,updated_at=?3 WHERE id=?1",
            params![id, mode, now()],
        )?;
        if changed == 0 {
            bail!("session not found");
        }
        Ok(())
    }

    pub fn create_turn(&self, session_id: &str, message_id: &str) -> Result<Value> {
        let id = Uuid::new_v4().to_string();
        let timestamp = now();
        self.conn().execute(
            "INSERT INTO turns(id,session_id,message_id,status,created_at,updated_at) VALUES(?1,?2,?3,'queued',?4,?4)",
            params![id, session_id, message_id, timestamp],
        )?;
        self.turn(&id)?.context("created turn missing")
    }

    pub fn turn(&self, id: &str) -> Result<Option<Value>> {
        self.conn()
            .query_row(
                "SELECT id,session_id,message_id,status,cwd_snapshot,additional_directories_snapshot,created_at,updated_at FROM turns WHERE id=?1",
                [id],
                row_turn,
            )
            .optional()
            .map_err(Into::into)
    }

    pub fn turn_for_message(&self, message_id: &str) -> Result<Option<Value>> {
        self.conn()
            .query_row(
                "SELECT id,session_id,message_id,status,cwd_snapshot,additional_directories_snapshot,created_at,updated_at FROM turns WHERE message_id=?1",
                [message_id],
                row_turn,
            )
            .optional()
            .map_err(Into::into)
    }

    pub fn turns(&self, session_id: Option<&str>) -> Result<Vec<Value>> {
        let conn = self.conn();
        let mut statement = conn.prepare(
            "SELECT id,session_id,message_id,status,cwd_snapshot,additional_directories_snapshot,created_at,updated_at FROM turns WHERE (?1 IS NULL OR session_id=?1) ORDER BY created_at,id",
        )?;
        Ok(statement
            .query_map([session_id], row_turn)?
            .collect::<rusqlite::Result<Vec<_>>>()?)
    }

    pub fn set_turn_context(
        &self,
        id: &str,
        cwd: &Path,
        additional_directories: &Value,
    ) -> Result<()> {
        self.conn().execute(
            "UPDATE turns SET cwd_snapshot=?2,additional_directories_snapshot=?3,updated_at=?4 WHERE id=?1",
            params![
                id,
                cwd.to_string_lossy().as_ref(),
                additional_directories.to_string(),
                now()
            ],
        )?;
        Ok(())
    }

    pub fn set_turn_status(&self, id: &str, status: &str) -> Result<Value> {
        let changed = self.conn().execute(
            "UPDATE turns SET status=?2,updated_at=?3 WHERE id=?1",
            params![id, status, now()],
        )?;
        if changed == 0 {
            bail!("turn not found");
        }
        self.turn(id)?.context("updated turn missing")
    }

    pub fn set_active_turn_status(&self, session_id: &str, status: &str) -> Result<Option<Value>> {
        let id = self
            .conn()
            .query_row(
                "SELECT id FROM turns WHERE session_id=?1 AND status IN ('queued','running','waiting_permission','waiting_input') ORDER BY CASE WHEN status='queued' THEN 1 ELSE 0 END,created_at LIMIT 1",
                [session_id],
                |row| row.get::<_, String>(0),
            )
            .optional()?;
        id.map(|id| self.set_turn_status(&id, status)).transpose()
    }

    pub fn add_message(
        &self,
        session_id: &str,
        role: &str,
        content: Value,
        status: &str,
    ) -> Result<Value> {
        let id = Uuid::new_v4().to_string();
        let timestamp = now();
        self.conn().execute("INSERT INTO messages(id,session_id,role,content,status,created_at,updated_at) VALUES(?1,?2,?3,?4,?5,?6,?6)",params![id,session_id,role,content.to_string(),status,timestamp])?;
        Ok(
            json!({"id":id,"sessionId":session_id,"role":role,"content":content,"status":status,"createdAt":timestamp,"updatedAt":timestamp}),
        )
    }
    pub fn update_message(&self, id: &str, content: Value, status: &str) -> Result<()> {
        self.conn().execute(
            "UPDATE messages SET content=?2,status=?3,updated_at=?4 WHERE id=?1",
            params![id, content.to_string(), status, now()],
        )?;
        Ok(())
    }

    pub fn save_attachment(&self, session_id: &str, path: &Path) -> Result<Value> {
        let canonical = path
            .canonicalize()
            .with_context(|| format!("cannot access attachment {}", path.display()))?;
        let metadata = std::fs::metadata(&canonical)?;
        if !metadata.is_file() {
            bail!("attachment is not a file");
        }
        let filename = canonical
            .file_name()
            .context("attachment has no filename")?
            .to_string_lossy()
            .into_owned();
        let mime_type = mime_guess::from_path(&canonical)
            .first_or_octet_stream()
            .to_string();
        let size = i64::try_from(metadata.len()).context("attachment size exceeds SQLite limit")?;
        let id = Uuid::new_v4().to_string();
        let timestamp = now();
        let path = canonical.to_string_lossy().into_owned();
        let conn = self.conn();
        conn.execute(
            "DELETE FROM attachments WHERE session_id=?1 AND path=?2",
            params![session_id, path],
        )?;
        conn.execute(
            "INSERT INTO attachments(id,session_id,filename,mime_type,path,size,created_at) VALUES(?1,?2,?3,?4,?5,?6,?7)",
            params![id, session_id, filename, mime_type, path, size, timestamp],
        )?;
        Ok(
            json!({"id":id,"sessionId":session_id,"filename":filename,"mimeType":mime_type,"path":path,"size":size,"createdAt":timestamp}),
        )
    }

    pub fn attachments(&self, session_id: &str) -> Result<Vec<Value>> {
        let conn = self.conn();
        let mut statement = conn.prepare(
            "SELECT id,session_id,filename,mime_type,path,size,created_at FROM attachments WHERE session_id=?1 ORDER BY created_at,id",
        )?;
        Ok(statement
            .query_map([session_id], |row| {
                Ok(json!({"id":row.get::<_,String>(0)?,"sessionId":row.get::<_,String>(1)?,"filename":row.get::<_,String>(2)?,"mimeType":row.get::<_,String>(3)?,"path":row.get::<_,String>(4)?,"size":row.get::<_,i64>(5)?,"createdAt":row.get::<_,String>(6)?}))
            })?
            .collect::<rusqlite::Result<Vec<_>>>()?)
    }

    pub fn record_terminal(&self, id: Uuid, project_id: Option<Uuid>, cwd: &Path) -> Result<Value> {
        let timestamp = now();
        let cwd = cwd
            .canonicalize()
            .unwrap_or_else(|_| cwd.to_owned())
            .to_string_lossy()
            .into_owned();
        self.conn().execute(
            "INSERT OR REPLACE INTO terminal_metadata(id,project_id,cwd,status,created_at,updated_at) VALUES(?1,?2,?3,'running',?4,?4)",
            params![id.to_string(), project_id.map(|id| id.to_string()), cwd, timestamp],
        )?;
        Ok(
            json!({"id":id,"projectId":project_id,"cwd":cwd,"status":"running","createdAt":timestamp,"updatedAt":timestamp}),
        )
    }

    pub fn set_terminal_status(&self, id: Uuid, status: &str) -> Result<()> {
        self.conn().execute(
            "UPDATE terminal_metadata SET status=?2,updated_at=?3 WHERE id=?1",
            params![id.to_string(), status, now()],
        )?;
        Ok(())
    }

    pub fn message(&self, id: &str) -> Result<Option<Value>> {
        self.conn()
            .query_row(
                "SELECT id,session_id,role,content,status,created_at,updated_at FROM messages WHERE id=?1",
                [id],
                row_message,
            )
            .optional()
            .map_err(Into::into)
    }
    pub fn remove_queued_message(&self, id: &str) -> Result<()> {
        self.conn()
            .execute("DELETE FROM messages WHERE id=?1 AND status='queued'", [id])?;
        Ok(())
    }
    pub fn messages(&self, session_id: &str) -> Result<Vec<Value>> {
        let conn = self.conn();
        let mut s=conn.prepare("SELECT id,session_id,role,content,status,created_at,updated_at FROM messages WHERE session_id=?1 ORDER BY updated_at,id")?;
        Ok(s.query_map([session_id], row_message)?
            .collect::<rusqlite::Result<Vec<_>>>()?)
    }

    pub fn add_structured_event(&self, session_id: &str, event: &Value) -> Result<Value> {
        let event_type = event["type"].as_str().unwrap_or("unknown");
        let timestamp = now();
        let conn = self.conn();
        conn.execute(
            "INSERT INTO structured_events(session_id,event_type,payload,created_at) VALUES(?1,?2,?3,?4)",
            params![session_id, event_type, event.to_string(), timestamp],
        )?;
        Ok(
            json!({"id":conn.last_insert_rowid(),"sessionId":session_id,"type":event_type,"payload":event,"createdAt":timestamp}),
        )
    }

    pub fn structured_events(&self, session_id: &str) -> Result<Vec<Value>> {
        let conn = self.conn();
        let mut stmt = conn.prepare("SELECT id,event_type,payload,created_at FROM structured_events WHERE session_id=?1 ORDER BY id")?;
        Ok(stmt.query_map([session_id], |r| Ok(json!({"id":r.get::<_,i64>(0)?,"sessionId":session_id,"type":r.get::<_,String>(1)?,"payload":serde_json::from_str::<Value>(&r.get::<_,String>(2)?).unwrap_or(Value::Null),"createdAt":r.get::<_,String>(3)?})))?.collect::<rusqlite::Result<Vec<_>>>()?)
    }

    pub fn queued_messages(&self, session_id: &str) -> Result<Vec<Value>> {
        let conn = self.conn();
        let mut s=conn.prepare("SELECT id,content FROM messages WHERE session_id=?1 AND role='user' AND status='queued' ORDER BY created_at,id")?;
        Ok(s.query_map([session_id],|r|Ok(json!({"id":r.get::<_,String>(0)?,"content":serde_json::from_str::<Value>(&r.get::<_,String>(1)?).unwrap_or(Value::Null)})))?.collect::<rusqlite::Result<Vec<_>>>()?)
    }

    pub fn save_skill_source(
        &self,
        scope: &str,
        path: &Path,
        source: Option<&Value>,
        enabled: bool,
    ) -> Result<()> {
        self.conn().execute(
            "INSERT INTO skill_sources(scope,path,git_url,git_ref,git_commit,enabled) VALUES(?1,?2,?3,?4,?5,?6) ON CONFLICT(scope,path) DO UPDATE SET git_url=excluded.git_url,git_ref=excluded.git_ref,git_commit=excluded.git_commit,enabled=excluded.enabled",
            params![
                scope,
                path.to_string_lossy().as_ref(),
                source.and_then(|value| value["url"].as_str()),
                source.and_then(|value| value["reference"].as_str()),
                source.and_then(|value| value["commit"].as_str()),
                enabled,
            ],
        )?;
        Ok(())
    }

    pub fn remove_skill_source(&self, path: &Path) -> Result<()> {
        self.conn().execute(
            "DELETE FROM skill_sources WHERE path=?1",
            [path.to_string_lossy().as_ref()],
        )?;
        Ok(())
    }

    pub fn skill_sources(&self) -> Result<Vec<Value>> {
        let conn = self.conn();
        let mut statement = conn.prepare(
            "SELECT scope,path,git_url,git_ref,git_commit,enabled FROM skill_sources ORDER BY scope,path",
        )?;
        Ok(statement
            .query_map([], |row| {
                Ok(json!({"scope":row.get::<_,String>(0)?,"path":row.get::<_,String>(1)?,"gitUrl":row.get::<_,Option<String>>(2)?,"gitRef":row.get::<_,Option<String>>(3)?,"gitCommit":row.get::<_,Option<String>>(4)?,"enabled":row.get::<_,bool>(5)?}))
            })?
            .collect::<rusqlite::Result<Vec<_>>>()?)
    }

    pub fn save_quota(&self, snapshot: Value) -> Result<Value> {
        if snapshot["remainingPercentages"]
            .as_array()
            .is_none_or(Vec::is_empty)
        {
            bail!("refusing to save an invalid quota snapshot");
        }
        let timestamp = now();
        self.conn().execute(
            "INSERT INTO quota_snapshots(payload,fetched_at) VALUES(?1,?2)",
            params![snapshot.to_string(), timestamp],
        )?;
        Ok(json!({"snapshot":snapshot,"fetchedAt":timestamp}))
    }
    pub fn latest_quota(&self) -> Result<Option<Value>> {
        let conn = self.conn();
        let mut statement =
            conn.prepare("SELECT payload,fetched_at FROM quota_snapshots ORDER BY id DESC")?;
        let rows = statement.query_map([], |row| {
            Ok((row.get::<_, String>(0)?, row.get::<_, String>(1)?))
        })?;
        for row in rows {
            let (payload, fetched_at) = row?;
            let snapshot = serde_json::from_str::<Value>(&payload).unwrap_or(Value::Null);
            if snapshot["remainingPercentages"]
                .as_array()
                .is_some_and(|values| !values.is_empty())
            {
                return Ok(Some(json!({"snapshot":snapshot,"fetchedAt":fetched_at})));
            }
        }
        Ok(None)
    }
}

fn reconcile_false_completed_background_tasks(conn: &mut Connection) -> Result<usize> {
    let candidates = {
        let mut statement = conn.prepare(
            "SELECT s.id,m.id,m.content,t.id
             FROM sessions s
             JOIN messages m ON m.id=(
                 SELECT id FROM messages
                 WHERE session_id=s.id AND role='assistant'
                 ORDER BY created_at DESC,id DESC LIMIT 1
             )
             JOIN turns t ON t.id=(
                 SELECT id FROM turns
                 WHERE session_id=s.id
                 ORDER BY created_at DESC,id DESC LIMIT 1
             )
             WHERE s.status='completed' AND m.status='completed' AND t.status='completed'",
        )?;
        statement
            .query_map([], |row| {
                Ok((
                    row.get::<_, String>(0)?,
                    row.get::<_, String>(1)?,
                    row.get::<_, String>(2)?,
                    row.get::<_, String>(3)?,
                ))
            })?
            .collect::<rusqlite::Result<Vec<_>>>()?
    };
    let affected = candidates
        .into_iter()
        .filter(|(_, _, content, _)| has_unresolved_running_event(content))
        .collect::<Vec<_>>();
    if affected.is_empty() {
        return Ok(0);
    }
    let timestamp = now();
    let transaction = conn.transaction()?;
    for (session_id, message_id, _, turn_id) in &affected {
        transaction.execute(
            "UPDATE sessions SET status='interrupted',updated_at=?2 WHERE id=?1",
            params![session_id, timestamp],
        )?;
        transaction.execute(
            "UPDATE turns SET status='interrupted',updated_at=?2 WHERE id=?1",
            params![turn_id, timestamp],
        )?;
        transaction.execute(
            "UPDATE messages SET status='interrupted',updated_at=?2 WHERE id=?1",
            params![message_id, timestamp],
        )?;
    }
    transaction.commit()?;
    Ok(affected.len())
}

fn has_unresolved_running_event(content: &str) -> bool {
    let Ok(content) = serde_json::from_str::<Value>(content) else {
        return false;
    };
    let mut statuses = HashMap::<String, &str>::new();
    for event in content["structuredEvents"].as_array().into_iter().flatten() {
        let event_type = event["type"].as_str().unwrap_or_default();
        if matches!(event_type, "user" | "text" | "title") {
            continue;
        }
        let key = format!(
            "{}:{event_type}:{}",
            event["index"],
            event["name"].as_str().unwrap_or_default()
        );
        statuses.insert(key, event["status"].as_str().unwrap_or("UNKNOWN"));
    }
    statuses.values().any(|status| *status == "RUNNING")
}

fn row_project_base(r: &rusqlite::Row<'_>) -> rusqlite::Result<Value> {
    Ok(json!({
        "id": r.get::<_, String>(0)?,
        "customName": r.get::<_, Option<String>>(1)?,
        "createdAt": r.get::<_, String>(2)?,
        "updatedAt": r.get::<_, String>(3)?,
    }))
}

fn hydrate_project(conn: &Connection, mut project: Value, projects_root: &Path) -> Result<Value> {
    let id = project["id"].as_str().context("project id missing")?;
    let runtime_path = projects_root.join(id).join("runtime");
    let mut statement = conn.prepare(
        "SELECT id,path,position,created_at FROM project_folders WHERE project_id=?1 ORDER BY position,id",
    )?;
    let folders = statement
        .query_map([id], |row| {
            Ok(json!({
                "id": row.get::<_, String>(0)?,
                "path": row.get::<_, String>(1)?,
                "position": row.get::<_, i64>(2)?,
                "createdAt": row.get::<_, String>(3)?,
            }))
        })?
        .collect::<rusqlite::Result<Vec<_>>>()?;
    let first_path = folders.first().and_then(|folder| folder["path"].as_str());
    let name = project["customName"]
        .as_str()
        .map(str::to_owned)
        .or_else(|| {
            first_path.and_then(|path| {
                Path::new(path)
                    .file_name()
                    .map(|name| name.to_string_lossy().into_owned())
            })
        })
        .unwrap_or_else(|| "Untitled project".to_owned());
    project["name"] = json!(name);
    project["folders"] = json!(folders);
    project["runtimePath"] = json!(runtime_path);
    Ok(project)
}

fn row_session(r: &rusqlite::Row<'_>) -> rusqlite::Result<Value> {
    Ok(json!({
        "id":r.get::<_,String>(0)?,
        "projectId":r.get::<_,Option<String>>(1)?,
        "provider":r.get::<_,String>(2)?,
        "externalId":r.get::<_,Option<String>>(3)?,
        "workspacePath":r.get::<_,String>(4)?,
        "title":r.get::<_,String>(5)?,
        "status":r.get::<_,String>(6)?,
        "archivedAt":r.get::<_,Option<String>>(7)?,
        "createdAt":r.get::<_,String>(8)?,
        "updatedAt":r.get::<_,String>(9)?,
        "permissionMode":r.get::<_,String>(10)?,
        "model":r.get::<_,Option<String>>(11)?,
    }))
}

fn row_message(r: &rusqlite::Row<'_>) -> rusqlite::Result<Value> {
    Ok(json!({
        "id": r.get::<_, String>(0)?,
        "sessionId": r.get::<_, String>(1)?,
        "role": r.get::<_, String>(2)?,
        "content": serde_json::from_str::<Value>(&r.get::<_, String>(3)?).unwrap_or(Value::Null),
        "status": r.get::<_, String>(4)?,
        "createdAt": r.get::<_, String>(5)?,
        "updatedAt": r.get::<_, String>(6)?,
    }))
}

fn row_turn(r: &rusqlite::Row<'_>) -> rusqlite::Result<Value> {
    Ok(json!({
        "id": r.get::<_, String>(0)?,
        "sessionId": r.get::<_, String>(1)?,
        "messageId": r.get::<_, Option<String>>(2)?,
        "status": r.get::<_, String>(3)?,
        "cwdSnapshot": r.get::<_, Option<String>>(4)?,
        "additionalDirectoriesSnapshot": r.get::<_, Option<String>>(5)?
            .and_then(|value| serde_json::from_str::<Value>(&value).ok()),
        "createdAt": r.get::<_, String>(6)?,
        "updatedAt": r.get::<_, String>(7)?,
    }))
}

fn row_provider_conversation(r: &rusqlite::Row<'_>) -> rusqlite::Result<Value> {
    Ok(json!({
        "id": r.get::<_, String>(0)?,
        "sessionId": r.get::<_, String>(1)?,
        "provider": r.get::<_, String>(2)?,
        "externalId": r.get::<_, String>(3)?,
        "providerWorkspaceId": r.get::<_, Option<String>>(4)?,
        "cwdSnapshot": r.get::<_, String>(5)?,
        "additionalDirectoriesSnapshot": r.get::<_, Option<String>>(6)?
            .and_then(|value| serde_json::from_str::<Value>(&value).ok()),
        "status": r.get::<_, String>(7)?,
        "createdAt": r.get::<_, String>(8)?,
        "endedAt": r.get::<_, Option<String>>(9)?,
        "endReason": r.get::<_, Option<String>>(10)?,
    }))
}
fn now() -> String {
    Utc::now().to_rfc3339()
}

const SCHEMA_V4: &str = r#"
CREATE TABLE IF NOT EXISTS projects(id TEXT PRIMARY KEY,custom_name TEXT,created_at TEXT NOT NULL,updated_at TEXT NOT NULL);
CREATE TABLE IF NOT EXISTS project_folders(id TEXT PRIMARY KEY,project_id TEXT NOT NULL REFERENCES projects(id) ON DELETE CASCADE,path TEXT NOT NULL,position INTEGER NOT NULL,created_at TEXT NOT NULL,UNIQUE(project_id,path));
CREATE TABLE IF NOT EXISTS sessions(id TEXT PRIMARY KEY,project_id TEXT REFERENCES projects(id) ON DELETE SET NULL,provider TEXT NOT NULL,external_id TEXT,workspace_path TEXT NOT NULL UNIQUE,title TEXT NOT NULL,status TEXT NOT NULL,archived_at TEXT,created_at TEXT NOT NULL,updated_at TEXT NOT NULL,permission_mode TEXT NOT NULL DEFAULT 'workspace',model TEXT);
CREATE INDEX IF NOT EXISTS sessions_project_updated ON sessions(project_id,archived_at,updated_at DESC);
CREATE TABLE IF NOT EXISTS session_provider_conversations(id TEXT PRIMARY KEY,session_id TEXT NOT NULL REFERENCES sessions(id) ON DELETE CASCADE,provider TEXT NOT NULL,external_id TEXT NOT NULL,provider_workspace_id TEXT,cwd_snapshot TEXT NOT NULL,additional_directories_snapshot TEXT NOT NULL,status TEXT NOT NULL,created_at TEXT NOT NULL,ended_at TEXT,end_reason TEXT,UNIQUE(session_id,provider,external_id));
CREATE UNIQUE INDEX IF NOT EXISTS session_one_active_provider_conversation ON session_provider_conversations(session_id,provider) WHERE status='active';
CREATE TABLE IF NOT EXISTS turns(id TEXT PRIMARY KEY,session_id TEXT NOT NULL REFERENCES sessions(id) ON DELETE CASCADE,message_id TEXT,status TEXT NOT NULL,cwd_snapshot TEXT,additional_directories_snapshot TEXT,created_at TEXT NOT NULL,updated_at TEXT NOT NULL);
CREATE TABLE IF NOT EXISTS messages(id TEXT PRIMARY KEY,session_id TEXT NOT NULL REFERENCES sessions(id) ON DELETE CASCADE,role TEXT NOT NULL,content TEXT NOT NULL,status TEXT NOT NULL,created_at TEXT NOT NULL,updated_at TEXT NOT NULL);
CREATE INDEX IF NOT EXISTS messages_session_created ON messages(session_id,created_at);
CREATE TABLE IF NOT EXISTS structured_events(id INTEGER PRIMARY KEY AUTOINCREMENT,session_id TEXT NOT NULL REFERENCES sessions(id) ON DELETE CASCADE,event_type TEXT NOT NULL,payload TEXT NOT NULL,created_at TEXT NOT NULL);
CREATE TABLE IF NOT EXISTS attachments(id TEXT PRIMARY KEY,session_id TEXT REFERENCES sessions(id) ON DELETE CASCADE,filename TEXT NOT NULL,mime_type TEXT NOT NULL,path TEXT NOT NULL,size INTEGER NOT NULL,created_at TEXT NOT NULL);
CREATE TABLE IF NOT EXISTS terminal_metadata(id TEXT PRIMARY KEY,project_id TEXT,cwd TEXT NOT NULL,status TEXT NOT NULL,created_at TEXT NOT NULL,updated_at TEXT NOT NULL);
CREATE TABLE IF NOT EXISTS skill_sources(scope TEXT NOT NULL,path TEXT NOT NULL,git_url TEXT,git_ref TEXT,git_commit TEXT,enabled INTEGER NOT NULL DEFAULT 1,PRIMARY KEY(scope,path));
CREATE TABLE IF NOT EXISTS quota_snapshots(id INTEGER PRIMARY KEY AUTOINCREMENT,payload TEXT NOT NULL,fetched_at TEXT NOT NULL);
CREATE TABLE IF NOT EXISTS events(seq INTEGER PRIMARY KEY AUTOINCREMENT,topic TEXT NOT NULL,payload TEXT NOT NULL,created_at TEXT NOT NULL);
CREATE TABLE IF NOT EXISTS provider_bindings(provider TEXT NOT NULL,scope_type TEXT NOT NULL,scope_id TEXT NOT NULL,external_id TEXT NOT NULL,updated_at TEXT NOT NULL,PRIMARY KEY(provider,scope_type,scope_id));
"#;

fn canonical_directory(path: &Path) -> Result<String> {
    let canonical = path
        .canonicalize()
        .with_context(|| format!("cannot access {}", path.display()))?;
    if !canonical.is_dir() {
        bail!("path is not a directory");
    }
    Ok(canonical.to_string_lossy().into_owned())
}

fn ensure_runtime_directory(runtime: &Path) -> Result<()> {
    std::fs::create_dir_all(runtime)?;
    let agents = runtime.join("AGENTS.md");
    let temporary = runtime.join(format!(".AGENTS.md.{}.tmp", Uuid::new_v4()));
    std::fs::write(&temporary, RUNTIME_AGENTS_MD)?;
    std::fs::rename(&temporary, &agents)?;
    Ok(())
}

fn remove_managed_directory(path: &Path) -> Result<()> {
    match std::fs::remove_dir_all(path) {
        Ok(()) => Ok(()),
        Err(error) if error.kind() == std::io::ErrorKind::NotFound => Ok(()),
        Err(error) => Err(error.into()),
    }
}

fn table_exists(conn: &Connection, table: &str) -> Result<bool> {
    Ok(conn.query_row(
        "SELECT EXISTS(SELECT 1 FROM sqlite_master WHERE type='table' AND name=?1)",
        [table],
        |row| row.get(0),
    )?)
}

fn initialize_schema(conn: &Connection) -> Result<()> {
    if table_exists(conn, "projects")? {
        let version: i64 = conn.pragma_query_value(None, "user_version", |row| row.get(0))?;
        if version != 4 {
            bail!("unsupported development database schema; remove riz.db and restart rizd");
        }
    }
    conn.execute_batch(SCHEMA_V4)?;
    let has_model: bool = conn.query_row(
        "SELECT COUNT(*) > 0 FROM pragma_table_info('sessions') WHERE name='model'",
        [],
        |r| r.get(0),
    )?;
    if !has_model {
        conn.execute("ALTER TABLE sessions ADD COLUMN model TEXT", [])?;
    }
    conn.pragma_update(None, "user_version", 4)?;
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn project_session_hierarchy() {
        let d = tempfile::tempdir().unwrap();
        let db = Database::open(&d.path().join("r.db")).unwrap();
        let p = db
            .create_project(Some("Demo"), &[d.path().to_owned()])
            .unwrap();
        let s = db
            .create_session(
                p["id"].as_str(),
                None,
                "mock",
                None,
                &d.path().join("sessions"),
            )
            .unwrap();
        assert_eq!(s["projectId"], p["id"]);
        assert_eq!(s["permissionMode"], "workspace");
        assert!(p.get("primaryPath").is_none());
        assert!(p["folders"][0].get("isPrimary").is_none());
        assert_eq!(
            p["runtimePath"],
            d.path()
                .join("projects")
                .join(p["id"].as_str().unwrap())
                .join("runtime")
                .to_string_lossy()
                .as_ref()
        );
        assert_eq!(
            db.sessions(Some(p["id"].as_str().unwrap()), false)
                .unwrap()
                .len(),
            1
        );
    }

    #[test]
    fn rejects_pre_release_database_schemas_instead_of_migrating_them() {
        let directory = tempfile::tempdir().unwrap();
        let path = directory.path().join("old.db");
        let connection = Connection::open(&path).unwrap();
        connection
            .execute("CREATE TABLE projects(id TEXT PRIMARY KEY)", [])
            .unwrap();
        drop(connection);

        let error = match Database::open(&path) {
            Ok(_) => panic!("old schema unexpectedly opened"),
            Err(error) => error,
        };
        assert!(error.to_string().contains("remove riz.db"));
    }

    #[test]
    fn unbound_session_uses_its_runtime_and_can_move_into_a_project() {
        let directory = tempfile::tempdir().unwrap();
        let db = Database::open(&directory.path().join("riz.db")).unwrap();
        let session = db
            .create_session_with_permission(
                None,
                Some("Quick chat"),
                "mock",
                None,
                "full",
                &directory.path().join("sessions"),
            )
            .unwrap();
        assert!(session["projectId"].is_null());
        assert_eq!(session["permissionMode"], "full");
        let context = db
            .execution_context(session["id"].as_str().unwrap())
            .unwrap();
        assert!(context["cwd"].as_str().unwrap().ends_with("/runtime"));

        let message = db
            .add_message(
                session["id"].as_str().unwrap(),
                "user",
                json!({"text":"snapshot"}),
                "queued",
            )
            .unwrap();
        let turn = db
            .create_turn(
                session["id"].as_str().unwrap(),
                message["id"].as_str().unwrap(),
            )
            .unwrap();
        db.set_turn_context(
            turn["id"].as_str().unwrap(),
            Path::new(context["cwd"].as_str().unwrap()),
            &context["additionalDirectories"],
        )
        .unwrap();
        let turn = db.turn(turn["id"].as_str().unwrap()).unwrap().unwrap();
        assert_eq!(turn["cwdSnapshot"], context["cwd"]);
        assert_eq!(
            turn["additionalDirectoriesSnapshot"],
            context["additionalDirectories"]
        );

        let project = db
            .create_project(Some("Demo"), &[directory.path().to_owned()])
            .unwrap();
        let moved = db
            .move_session(session["id"].as_str().unwrap(), project["id"].as_str())
            .unwrap();
        assert_eq!(moved["projectId"], project["id"]);
        let project_context = db
            .execution_context(session["id"].as_str().unwrap())
            .unwrap();
        assert_eq!(
            project_context["cwd"],
            directory
                .path()
                .join("projects")
                .join(project["id"].as_str().unwrap())
                .join("runtime")
                .to_string_lossy()
                .as_ref()
        );
        assert_eq!(
            project_context["additionalDirectories"][0],
            directory
                .path()
                .canonicalize()
                .unwrap()
                .to_string_lossy()
                .as_ref()
        );
    }

    #[test]
    fn project_folders_are_peers_and_do_not_invalidate_provider_context() {
        let directory = tempfile::tempdir().unwrap();
        let first = directory.path().join("first");
        let second = directory.path().join("second");
        std::fs::create_dir_all(&first).unwrap();
        std::fs::create_dir_all(&second).unwrap();
        let db = Database::open(&directory.path().join("riz.db")).unwrap();

        let empty = db.create_project(None, &[]).unwrap();
        assert!(empty.get("primaryPath").is_none());
        assert!(empty["folders"].as_array().unwrap().is_empty());
        assert!(empty.get("path").is_none());

        let project = db
            .create_project(None, &[first.clone(), second.clone()])
            .unwrap();
        let project_id = project["id"].as_str().unwrap();
        assert_eq!(project["name"], "first");
        assert_eq!(project["folders"].as_array().unwrap().len(), 2);
        assert!(
            project["folders"]
                .as_array()
                .unwrap()
                .iter()
                .all(|folder| folder.get("isPrimary").is_none())
        );

        let session = db
            .create_session(
                Some(project_id),
                None,
                "agy",
                Some("conversation-old"),
                &directory.path().join("sessions"),
            )
            .unwrap();
        db.set_provider_binding("agy", "project", project_id, "project-old")
            .unwrap();
        let original_context = db
            .execution_context(session["id"].as_str().unwrap())
            .unwrap();
        assert_eq!(
            original_context["additionalDirectories"]
                .as_array()
                .unwrap()
                .len(),
            2
        );
        let first_id = project["folders"][0]["id"].as_str().unwrap();
        let changed = db.remove_project_folder(project_id, first_id).unwrap();
        assert_eq!(changed["folders"].as_array().unwrap().len(), 1);
        assert!(
            db.session(session["id"].as_str().unwrap())
                .unwrap()
                .unwrap()["externalId"]
                == "conversation-old"
        );
        assert_eq!(
            db.provider_binding("agy", "project", project_id).unwrap(),
            Some("project-old".to_owned())
        );
        let context = db
            .execution_context(session["id"].as_str().unwrap())
            .unwrap();
        assert_eq!(context["cwd"], original_context["cwd"]);
        assert_eq!(
            context["additionalDirectories"].as_array().unwrap().len(),
            1
        );
        assert_eq!(
            context["additionalDirectories"][0],
            second.canonicalize().unwrap().to_string_lossy().as_ref()
        );
        assert!(context["cwd"].as_str().unwrap().ends_with("/runtime"));
    }

    #[test]
    fn project_and_session_runtimes_have_managed_agents_instructions() {
        let directory = tempfile::tempdir().unwrap();
        let db = Database::open(&directory.path().join("riz.db")).unwrap();
        let project = db.create_project(Some("Demo"), &[]).unwrap();
        let session = db
            .create_session(
                project["id"].as_str(),
                None,
                "agy",
                None,
                &directory.path().join("sessions"),
            )
            .unwrap();
        let project_context = db
            .execution_context(session["id"].as_str().unwrap())
            .unwrap();
        assert_eq!(
            std::fs::read_to_string(
                Path::new(project_context["cwd"].as_str().unwrap()).join("AGENTS.md")
            )
            .unwrap(),
            RUNTIME_AGENTS_MD
        );

        let quick = db
            .create_session(
                None,
                Some("Quick chat"),
                "agy",
                None,
                &directory.path().join("sessions"),
            )
            .unwrap();
        let quick_context = db.execution_context(quick["id"].as_str().unwrap()).unwrap();
        assert_eq!(
            std::fs::read_to_string(
                Path::new(quick_context["cwd"].as_str().unwrap()).join("AGENTS.md")
            )
            .unwrap(),
            RUNTIME_AGENTS_MD
        );
    }

    #[test]
    fn removing_project_can_detach_sessions_and_preserve_conversation_lineage() {
        let directory = tempfile::tempdir().unwrap();
        let db = Database::open(&directory.path().join("riz.db")).unwrap();
        let project = db
            .create_project(Some("Demo"), &[directory.path().to_owned()])
            .unwrap();
        let session = db
            .create_session(
                project["id"].as_str(),
                None,
                "agy",
                Some("conversation-old"),
                &directory.path().join("sessions"),
            )
            .unwrap();
        let workspace = PathBuf::from(session["workspacePath"].as_str().unwrap());
        let project_runtime = db
            .execution_context(session["id"].as_str().unwrap())
            .unwrap()["cwd"]
            .as_str()
            .map(PathBuf::from)
            .unwrap();
        let result = db
            .remove_project(project["id"].as_str().unwrap(), "detach_sessions")
            .unwrap();
        assert_eq!(result["detachedSessions"].as_array().unwrap().len(), 1);
        let session = db
            .session(session["id"].as_str().unwrap())
            .unwrap()
            .unwrap();
        assert!(session["projectId"].is_null());
        assert!(session["externalId"].is_null());
        assert!(workspace.join("runtime").is_dir());
        assert!(!project_runtime.exists());
        assert!(directory.path().exists());
        let conversations = db
            .provider_conversations(session["id"].as_str().unwrap())
            .unwrap();
        assert_eq!(conversations.len(), 1);
        assert_eq!(conversations[0]["externalId"], "conversation-old");
        assert_eq!(conversations[0]["status"], "superseded");
        assert_eq!(conversations[0]["endReason"], "project_removed");
    }

    #[test]
    fn moving_a_session_supersedes_the_active_provider_conversation() {
        let directory = tempfile::tempdir().unwrap();
        let first = directory.path().join("first");
        let second = directory.path().join("second");
        std::fs::create_dir_all(&first).unwrap();
        std::fs::create_dir_all(&second).unwrap();
        let db = Database::open(&directory.path().join("riz.db")).unwrap();
        let project = db
            .create_project(Some("Demo"), std::slice::from_ref(&first))
            .unwrap();
        let session = db
            .create_session(
                project["id"].as_str(),
                None,
                "agy",
                None,
                &directory.path().join("sessions"),
            )
            .unwrap();
        let context = db
            .execution_context(session["id"].as_str().unwrap())
            .unwrap();
        db.set_external_id(
            session["id"].as_str().unwrap(),
            "conversation-one",
            Some("workspace-one"),
            Path::new(context["cwd"].as_str().unwrap()),
            &context["additionalDirectories"],
        )
        .unwrap();

        db.move_session(session["id"].as_str().unwrap(), None)
            .unwrap();
        let moved = db
            .session(session["id"].as_str().unwrap())
            .unwrap()
            .unwrap();
        assert!(moved["externalId"].is_null());
        let old = db
            .provider_conversations(session["id"].as_str().unwrap())
            .unwrap();
        assert_eq!(old[0]["providerWorkspaceId"], "workspace-one");
        assert_eq!(old[0]["cwdSnapshot"], context["cwd"]);
        assert_eq!(
            old[0]["additionalDirectoriesSnapshot"],
            context["additionalDirectories"]
        );
        assert_eq!(old[0]["status"], "superseded");
        assert_eq!(old[0]["endReason"], "session_moved");

        let moved_context = db
            .execution_context(session["id"].as_str().unwrap())
            .unwrap();
        db.set_external_id(
            session["id"].as_str().unwrap(),
            "conversation-two",
            Some("workspace-two"),
            Path::new(moved_context["cwd"].as_str().unwrap()),
            &moved_context["additionalDirectories"],
        )
        .unwrap();
        let conversations = db
            .provider_conversations(session["id"].as_str().unwrap())
            .unwrap();
        assert_eq!(conversations.len(), 2);
        assert_eq!(conversations[0]["status"], "superseded");
        assert_eq!(conversations[1]["status"], "active");
        assert_eq!(conversations[1]["externalId"], "conversation-two");
        assert!(second.exists());
    }

    #[test]
    fn deleting_sessions_removes_only_riz_managed_directories() {
        let directory = tempfile::tempdir().unwrap();
        let user_folder = directory.path().join("user-project");
        std::fs::create_dir_all(&user_folder).unwrap();
        let user_file = user_folder.join("keep.txt");
        std::fs::write(&user_file, b"keep").unwrap();
        let db = Database::open(&directory.path().join("riz.db")).unwrap();
        let project = db
            .create_project(Some("Demo"), std::slice::from_ref(&user_folder))
            .unwrap();
        let first = db
            .create_session(
                project["id"].as_str(),
                None,
                "agy",
                Some("conversation-one"),
                &directory.path().join("sessions"),
            )
            .unwrap();
        let first_workspace = PathBuf::from(first["workspacePath"].as_str().unwrap());
        db.delete_session(first["id"].as_str().unwrap()).unwrap();
        assert!(db.session(first["id"].as_str().unwrap()).unwrap().is_none());
        assert!(!first_workspace.exists());
        assert!(user_file.exists());

        let second = db
            .create_session(
                project["id"].as_str(),
                None,
                "agy",
                Some("conversation-two"),
                &directory.path().join("sessions"),
            )
            .unwrap();
        let second_workspace = PathBuf::from(second["workspacePath"].as_str().unwrap());
        let result = db
            .remove_project(project["id"].as_str().unwrap(), "delete_sessions")
            .unwrap();
        assert_eq!(result["deletedSessionIds"][0], second["id"]);
        assert!(
            db.session(second["id"].as_str().unwrap())
                .unwrap()
                .is_none()
        );
        assert!(!second_workspace.exists());
        assert!(user_file.exists());
    }

    #[test]
    fn quota_history_ignores_invalid_snapshots() {
        let directory = tempfile::tempdir().unwrap();
        let db = Database::open(&directory.path().join("riz.db")).unwrap();
        assert!(
            db.save_quota(json!({"source":"pty","raw":"trust prompt"}))
                .is_err()
        );
        db.conn()
            .execute(
                "INSERT INTO quota_snapshots(payload,fetched_at) VALUES(?1,?2)",
                params![
                    json!({"source":"pty","raw":"old invalid"}).to_string(),
                    now()
                ],
            )
            .unwrap();
        assert!(db.latest_quota().unwrap().is_none());
        db.save_quota(json!({"source":"pty","remainingPercentages":[75.0]}))
            .unwrap();
        assert_eq!(
            db.latest_quota().unwrap().unwrap()["snapshot"]["remainingPercentages"][0],
            75.0
        );
    }

    #[test]
    fn turn_lifecycle_is_linked_to_its_message_and_interrupted_on_restart() {
        let directory = tempfile::tempdir().unwrap();
        let path = directory.path().join("riz.db");
        let (session_id, turn_id, message_id) = {
            let db = Database::open(&path).unwrap();
            let project = db
                .create_project(Some("Demo"), &[directory.path().to_owned()])
                .unwrap();
            let session = db
                .create_session(
                    project["id"].as_str(),
                    Some("Turn test"),
                    "mock",
                    None,
                    &directory.path().join("sessions"),
                )
                .unwrap();
            let message = db
                .add_message(
                    session["id"].as_str().unwrap(),
                    "user",
                    json!({"text":"hello"}),
                    "queued",
                )
                .unwrap();
            let turn = db
                .create_turn(
                    session["id"].as_str().unwrap(),
                    message["id"].as_str().unwrap(),
                )
                .unwrap();
            db.set_turn_status(turn["id"].as_str().unwrap(), "running")
                .unwrap();
            (
                session["id"].as_str().unwrap().to_owned(),
                turn["id"].as_str().unwrap().to_owned(),
                message["id"].as_str().unwrap().to_owned(),
            )
        };

        let reopened = Database::open(&path).unwrap();
        let turn = reopened.turn(&turn_id).unwrap().unwrap();
        assert_eq!(turn["sessionId"], session_id);
        assert_eq!(turn["messageId"], message_id);
        assert_eq!(turn["status"], "interrupted");
        assert_eq!(reopened.turns(Some(&session_id)).unwrap().len(), 1);
    }

    #[test]
    fn completed_session_with_unresolved_background_task_is_reconciled() {
        let directory = tempfile::tempdir().unwrap();
        let path = directory.path().join("riz.db");
        let (session_id, turn_id, assistant_id) = {
            let db = Database::open(&path).unwrap();
            let session = db
                .create_session(
                    None,
                    Some("Background task"),
                    "agy",
                    None,
                    &directory.path().join("sessions"),
                )
                .unwrap();
            let user = db
                .add_message(
                    session["id"].as_str().unwrap(),
                    "user",
                    json!({"text":"clone repositories"}),
                    "completed",
                )
                .unwrap();
            let turn = db
                .create_turn(
                    session["id"].as_str().unwrap(),
                    user["id"].as_str().unwrap(),
                )
                .unwrap();
            db.set_turn_status(turn["id"].as_str().unwrap(), "completed")
                .unwrap();
            let assistant = db
                .add_message(
                    session["id"].as_str().unwrap(),
                    "assistant",
                    json!({
                        "text":"running in background",
                        "structuredEvents":[{
                            "index":3,
                            "type":"tool_result",
                            "name":"run_command",
                            "status":"RUNNING"
                        }]
                    }),
                    "completed",
                )
                .unwrap();
            (
                session["id"].as_str().unwrap().to_owned(),
                turn["id"].as_str().unwrap().to_owned(),
                assistant["id"].as_str().unwrap().to_owned(),
            )
        };

        let reopened = Database::open(&path).unwrap();
        assert_eq!(
            reopened.session(&session_id).unwrap().unwrap()["status"],
            "interrupted"
        );
        assert_eq!(
            reopened.turn(&turn_id).unwrap().unwrap()["status"],
            "interrupted"
        );
        assert_eq!(
            reopened.message(&assistant_id).unwrap().unwrap()["status"],
            "interrupted"
        );
        drop(reopened);

        let reopened_again = Database::open(&path).unwrap();
        assert_eq!(
            reopened_again.session(&session_id).unwrap().unwrap()["status"],
            "interrupted"
        );
    }

    #[test]
    fn terminal_tool_update_does_not_trigger_background_reconciliation() {
        let content = json!({
            "structuredEvents":[
                {"index":3,"type":"tool_result","name":"run_command","status":"RUNNING"},
                {"index":3,"type":"tool_result","name":"run_command","status":"DONE"}
            ]
        });
        assert!(!has_unresolved_running_event(&content.to_string()));
    }

    #[test]
    fn attachments_and_terminal_metadata_are_persisted() {
        let directory = tempfile::tempdir().unwrap();
        let database_path = directory.path().join("riz.db");
        let terminal_id = Uuid::new_v4();
        let (session_id, project_id) = {
            let db = Database::open(&database_path).unwrap();
            let project = db
                .create_project(Some("Demo"), &[directory.path().to_owned()])
                .unwrap();
            let project_id = Uuid::parse_str(project["id"].as_str().unwrap()).unwrap();
            let session = db
                .create_session(
                    project["id"].as_str(),
                    Some("Attachment test"),
                    "mock",
                    None,
                    &directory.path().join("sessions"),
                )
                .unwrap();
            let attachment_path = directory.path().join("image.png");
            std::fs::write(&attachment_path, b"png-data").unwrap();
            let attachment = db
                .save_attachment(session["id"].as_str().unwrap(), &attachment_path)
                .unwrap();
            assert_eq!(attachment["mimeType"], "image/png");
            assert_eq!(
                db.attachments(session["id"].as_str().unwrap())
                    .unwrap()
                    .len(),
                1
            );
            db.record_terminal(terminal_id, Some(project_id), directory.path())
                .unwrap();
            (
                session["id"].as_str().unwrap().to_owned(),
                project_id.to_string(),
            )
        };

        let reopened = Database::open(&database_path).unwrap();
        assert_eq!(reopened.attachments(&session_id).unwrap().len(), 1);
        let (status, stored_project_id) = reopened
            .conn()
            .query_row(
                "SELECT status,project_id FROM terminal_metadata WHERE id=?1",
                [terminal_id.to_string()],
                |row| Ok((row.get::<_, String>(0)?, row.get::<_, String>(1)?)),
            )
            .unwrap();
        assert_eq!(status, "interrupted");
        assert_eq!(stored_project_id, project_id);
    }

    #[test]
    fn skill_source_metadata_is_upserted_and_removed() {
        let directory = tempfile::tempdir().unwrap();
        let db = Database::open(&directory.path().join("riz.db")).unwrap();
        let path = directory.path().join("demo-skill");
        db.save_skill_source(
            "project",
            &path,
            Some(&json!({"url":"https://example.invalid/skill.git","reference":"main","commit":"abc123"})),
            true,
        )
        .unwrap();
        db.save_skill_source(
            "project",
            &path,
            Some(&json!({"url":"https://example.invalid/skill.git","reference":"main","commit":"def456"})),
            false,
        )
        .unwrap();
        let sources = db.skill_sources().unwrap();
        assert_eq!(sources.len(), 1);
        assert_eq!(sources[0]["gitCommit"], "def456");
        assert_eq!(sources[0]["enabled"], false);
        db.remove_skill_source(&path).unwrap();
        assert!(db.skill_sources().unwrap().is_empty());
    }

    #[test]
    fn session_model_can_be_set_and_persisted() {
        let directory = tempfile::tempdir().unwrap();
        let db = Database::open(&directory.path().join("riz.db")).unwrap();
        let session = db
            .create_session_with_details(
                None,
                Some("Test session"),
                "agy",
                None,
                "workspace",
                Some("gemini-3.7-flash"),
                &directory.path().join("sessions"),
            )
            .unwrap();
        assert_eq!(session["model"], "gemini-3.7-flash");

        let updated = db
            .set_session_model(session["id"].as_str().unwrap(), Some("gemini-3.7-pro"))
            .unwrap();
        assert_eq!(updated["model"], "gemini-3.7-pro");

        let retrieved = db
            .session(session["id"].as_str().unwrap())
            .unwrap()
            .unwrap();
        assert_eq!(retrieved["model"], "gemini-3.7-pro");

        let cleared = db
            .set_session_model(session["id"].as_str().unwrap(), None)
            .unwrap();
        assert!(cleared["model"].is_null());
    }
}
