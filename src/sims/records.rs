use super::*;

/// What `stop` hands back: the session as served, and the recording it filed.
#[derive(Serialize)]
pub struct StopReceipt {
    #[serde(flatten)]
    pub session: Served,
    #[serde(skip)]
    pub media_id: Option<String>,
}

#[derive(Clone, Default, Serialize, Deserialize)]
pub(super) struct Ledger {
    #[serde(default)]
    pub(super) schema: u32,
    #[serde(default)]
    pub(super) sessions: Vec<Session>,
    /// Threads waiting for a simulator, first come first served.
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    pub(super) queue: Vec<Waiter>,
}

impl Ledger {
    pub(super) fn reservations(&self) -> Vec<Reservation> {
        self.sessions
            .iter()
            .filter(|s| s.reserves())
            .map(|s| Reservation {
                thread: s.thread_id.clone(),
                device: s.device_id.to_ascii_uppercase(),
            })
            .collect()
    }

    pub(super) fn session(&self, id: &str) -> Option<&Session> {
        self.sessions.iter().find(|s| s.id == id)
    }
}
