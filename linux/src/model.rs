use serde::{Deserialize, Serialize};
use serde_json::Value;
use unicode_general_category::{GeneralCategory, get_general_category};

#[derive(Clone, Debug, Default, PartialEq, Serialize, Deserialize)]
pub struct Activity {
    pub kind: String,
    pub text: String,
    pub timestamp: String,
}

#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
pub struct Session {
    pub id: String,
    pub project: String,
    pub model: String,
    pub state: String,
    pub updated_at: f64,
    pub stale: bool,
    pub subagent: bool,
    pub total_tokens: Option<u64>,
    pub limit_used_percent: Option<f64>,
    pub title: String,
    pub branch: String,
    pub last_prompt: String,
    pub last_activity: String,
    pub error: String,
    pub recent: Vec<Activity>,
}

impl Default for Session {
    fn default() -> Self {
        Self {
            id: String::new(),
            project: String::new(),
            model: String::new(),
            state: "unknown".into(),
            updated_at: 0.,
            stale: false,
            subagent: false,
            total_tokens: None,
            limit_used_percent: None,
            title: String::new(),
            branch: String::new(),
            last_prompt: String::new(),
            last_activity: String::new(),
            error: String::new(),
            recent: Vec::new(),
        }
    }
}

pub fn clean(text: &str, limit: usize, multiline: bool) -> String {
    text.chars()
        .take(limit)
        .map(|c| {
            if multiline && c == '\n' {
                return c;
            }
            match get_general_category(c) {
                GeneralCategory::Control
                | GeneralCategory::Format
                | GeneralCategory::PrivateUse
                | GeneralCategory::Surrogate
                | GeneralCategory::Unassigned => ' ',
                _ => c,
            }
        })
        .collect::<String>()
        .trim()
        .to_string()
}

fn text(v: &Value) -> String {
    clean(v.as_str().unwrap_or_default(), 512, false)
}
fn long(v: &Value) -> String {
    clean(v.as_str().unwrap_or_default(), 2000, true)
}
fn truthy(v: &Value) -> bool {
    match v {
        Value::Null => false,
        Value::Bool(b) => *b,
        Value::String(s) => !s.is_empty(),
        Value::Array(a) => !a.is_empty(),
        Value::Object(o) => !o.is_empty(),
        Value::Number(n) => n.as_f64() != Some(0.),
    }
}
fn human_phase(v: &Value) -> bool {
    v.is_null() || matches!(v.as_str(), Some("commentary" | "final" | "final_answer"))
}
fn content(v: &Value) -> String {
    if v.is_string() {
        return long(v);
    }
    let Some(blocks) = v.as_array() else {
        return String::new();
    };
    let s = blocks
        .iter()
        .take(32)
        .filter(|b| {
            matches!(
                b["type"].as_str(),
                Some("input_text" | "output_text" | "text" | "Text")
            )
        })
        .map(|b| long(&b["text"]))
        .collect::<Vec<_>>()
        .join("\n");
    clean(&s, 2000, true)
}

impl Session {
    pub fn project_name(&self) -> &str {
        std::path::Path::new(&self.project)
            .file_name()
            .and_then(|s| s.to_str())
            .unwrap_or("Unknown project")
    }
    pub fn heading(&self) -> &str {
        if !self.title.is_empty() {
            &self.title
        } else if !self.last_prompt.is_empty() {
            &self.last_prompt
        } else {
            "Untitled session"
        }
    }
    pub fn add(&mut self, kind: &str, value: &str, row: &Value) {
        let value = clean(value, 2000, true);
        if value.is_empty() {
            return;
        }
        if !self
            .recent
            .last()
            .is_some_and(|a| a.kind == kind && a.text == value)
        {
            self.recent.push(Activity {
                kind: kind.into(),
                text: value.clone(),
                timestamp: text(&row["timestamp"]),
            });
            if self.recent.len() > 12 {
                self.recent.remove(0);
            }
        }
        match kind {
            "user" => self.last_prompt = value,
            "assistant" | "tool" | "error" => self.last_activity = clean(&value, 512, false),
            _ => (),
        }
    }
    fn message(&mut self, role: &str, mut value: String, row: &Value) {
        if role == "user" {
            while let Some(start) = value.find("<environment_context>") {
                let Some(end) = value[start..].find("</environment_context>") else {
                    break;
                };
                value.replace_range(start..start + end + "</environment_context>".len(), "");
            }
            value = value.trim().into();
            if [
                "# AGENTS.md instructions",
                "<turn_aborted>",
                "<permissions instructions>",
                "<environment_context>",
            ]
            .iter()
            .any(|p| value.starts_with(p))
            {
                return;
            }
        }
        self.add(role, &value, row);
    }
    pub fn reduce(&mut self, row: &Value) {
        let p = &row["payload"];
        match row["type"].as_str().unwrap_or_default() {
            "session_meta" => {
                self.id = text(&p["id"]);
                self.project = text(&p["cwd"]);
                self.branch = text(&p["git"]["branch"]);
                self.title = text(if truthy(&p["thread_name"]) {
                    &p["thread_name"]
                } else {
                    &p["title"]
                });
                self.subagent = truthy(&p["parent_thread_id"]) || truthy(&p["source"]["subagent"]);
            }
            "turn_context" => {
                self.model = text(&p["model"]);
                let cwd = text(&p["cwd"]);
                if !cwd.is_empty() {
                    self.project = cwd;
                }
            }
            "response_item" => match p["type"].as_str().unwrap_or_default() {
                "message" if human_phase(&p["phase"]) => {
                    if let Some(role @ ("user" | "assistant")) = p["role"].as_str() {
                        self.message(role, content(&p["content"]), row);
                    }
                }
                "function_call" | "custom_tool_call" => {
                    let name = text(&p["name"]);
                    if !name.is_empty() {
                        self.add("tool", &format!("Tool: {name}"), row);
                    }
                }
                _ => (),
            },
            "event_msg" => match p["type"].as_str().unwrap_or_default() {
                "task_started" => {
                    self.state = "working".into();
                    self.error.clear();
                    self.last_activity = "Turn started".into();
                    self.add("status", "Turn started", row);
                }
                "task_complete" => {
                    let failed = truthy(&p["error"]);
                    self.state = if failed { "error" } else { "completed" }.into();
                    self.error = long(if p["error"].is_object() {
                        &p["error"]["message"]
                    } else {
                        &p["error"]
                    });
                    self.add("error", &self.error.clone(), row);
                    let reply = long(&p["last_agent_message"]);
                    if !self
                        .recent
                        .iter()
                        .any(|a| a.kind == "assistant" && a.text == reply)
                    {
                        self.add("assistant", &reply, row);
                    }
                    self.add(
                        "status",
                        if failed {
                            "Turn failed"
                        } else {
                            "Turn completed"
                        },
                        row,
                    );
                }
                "turn_aborted" => {
                    self.state = "interrupted".into();
                    self.add("status", "Turn interrupted", row);
                }
                "user_message" => self.message("user", long(&p["message"]), row),
                "agent_message" => self.message("assistant", long(&p["message"]), row),
                "item_completed" => {
                    let item = &p["item"];
                    match item["type"].as_str().unwrap_or_default() {
                        "UserMessage" | "AgentMessage" if human_phase(&item["phase"]) => {
                            self.message(
                                if item["type"] == "UserMessage" {
                                    "user"
                                } else {
                                    "assistant"
                                },
                                content(&item["content"]),
                                row,
                            );
                        }
                        kind @ ("CommandExecution" | "FileChange" | "McpToolCall") => {
                            let label = match kind {
                                "CommandExecution" => "Command",
                                "FileChange" => "File changes",
                                _ => "MCP tool",
                            };
                            let status = text(&item["status"]);
                            let status = if status.is_empty() {
                                "completed"
                            } else {
                                &status
                            };
                            let suffix = item["exit_code"]
                                .as_i64()
                                .map(|n| format!(" (exit {n})"))
                                .unwrap_or_default();
                            self.add("tool", &format!("{label}: {status}{suffix}"), row);
                        }
                        _ => (),
                    }
                }
                "token_count" => {
                    if let Some(n) = p["info"]["total_token_usage"]["total_tokens"]
                        .as_f64()
                        .filter(|n| n.is_finite() && *n >= 0.)
                    {
                        self.total_tokens = Some(n as u64);
                    }
                    self.limit_used_percent = p["rate_limits"]["primary"]["used_percent"]
                        .as_f64()
                        .filter(|n| n.is_finite() && (0. ..=100.).contains(n));
                }
                _ => (),
            },
            _ => (),
        }
    }
    pub fn history(&self) -> String {
        let mut entries: Vec<_> = self
            .recent
            .iter()
            .rev()
            .map(|a| format!("{}   {}\n{}", a.kind.to_uppercase(), a.timestamp, a.text))
            .collect();
        for (kind, value) in [("LATEST PROMPT", &self.last_prompt), ("ERROR", &self.error)] {
            if !value.is_empty() && !self.recent.iter().any(|a| &a.text == value) {
                entries.push(format!("{kind}\n{value}"));
            }
        }
        if entries.is_empty() {
            "No recent messages in the observed file tail.".into()
        } else {
            entries.join("\n\n")
        }
    }
}
