use super::*;

impl ThreadObservation {
    /// The wake-up its state calls for, if any: a stopped turn (done, error)
    /// or one waiting on its owner, each delivered once.
    pub(super) fn wake(&self) -> Option<WorkerEvent> {
        let kind = match self.phase() {
            Phase::Working => return None,
            Phase::NeedsYou => EventKind::NeedsYou,
            Phase::Error => EventKind::Error,
            Phase::Done => EventKind::Done,
        };
        Some(WorkerEvent {
            turn: self.turn.clone()?,
            kind,
            request: None,
        })
    }

    /// What to remember once a worker is working again: a question it was
    /// waiting on has been answered, so the next one in the same turn is new.
    pub(super) fn progressed(&self, notified: Option<&WorkerEvent>) -> Option<WorkerEvent> {
        let turn = self.turn.as_ref()?;
        let answered = notified.is_some_and(|n| &n.turn == turn && n.kind == EventKind::NeedsYou);
        (self.phase() == Phase::Working && answered).then(|| WorkerEvent {
            turn: turn.clone(),
            kind: EventKind::Working,
            request: None,
        })
    }
}

/// What a worker is doing, from T3's shell row, as the label views show.
pub fn worker_state(thread: &Value) -> &'static str {
    ThreadObservation::decode(thread).phase().label()
}

/// A fact from T3's shell and how fresh it is. `epoch` counts connections:
/// `current` facts come from the live subscription; `stale` ones are what
/// the last connection said. Stale facts may be shown, never acted on
/// destructively. `Current(None)` means T3 has no such thread.
#[derive(Clone, PartialEq, Eq, Debug)]
pub enum Observed<T> {
    Unavailable,
    Stale { epoch: u64, value: T },
    Current { epoch: u64, value: T },
}

impl<T> Observed<T> {
    /// The value if it is current.
    pub fn current(self) -> Option<T> {
        match self {
            Observed::Current { value, .. } => Some(value),
            _ => None,
        }
    }
    /// The value however fresh, for display.
    pub fn latest(self) -> Option<T> {
        match self {
            Observed::Current { value, .. } | Observed::Stale { value, .. } => Some(value),
            Observed::Unavailable => None,
        }
    }
}

/// The newest unanswered question or approval request in a thread's
/// projection: its pending runtime requests.
pub(super) fn pending_request(projection: &Value) -> Option<String> {
    projection["runtimeRequests"]
        .as_array()?
        .iter()
        .rev()
        .find(|r| r["status"] == "pending")
        .and_then(|r| r["id"].as_str())
        .map(str::to_string)
}

#[derive(Clone, Default)]
pub(super) struct Shell {
    pub(super) threads: HashMap<String, Arc<Value>>,
    pub(super) projects: HashMap<String, Arc<Value>>,
    pub(super) link: Link,
}

/// The shell subscription. Its maps outlive a disconnect, as stale facts.
#[derive(Clone, Copy, PartialEq, Eq, Debug)]
pub(super) enum Link {
    /// Not subscribed; the maps are what connection `epoch` last said.
    Offline {
        epoch: u64,
    },
    /// Subscribed; T3's snapshot has not arrived yet.
    Syncing {
        epoch: u64,
    },
    Current {
        epoch: u64,
    },
}

impl Default for Link {
    fn default() -> Self {
        Link::Offline { epoch: 0 }
    }
}

impl Link {
    pub(super) fn epoch(self) -> u64 {
        match self {
            Link::Offline { epoch } | Link::Syncing { epoch } | Link::Current { epoch } => epoch,
        }
    }
}

/// A receipt if `shell` is current and shows the thread's session stopped,
/// or no such thread.
pub(super) fn stopped_in(shell: &Shell, id: &str) -> Option<StopReceipt> {
    match shell.observe(id).current()? {
        Some(now) if now.execution != Execution::Stopped => None,
        _ => Some(StopReceipt(())),
    }
}

impl Shell {
    pub(super) fn current(&self) -> bool {
        matches!(self.link, Link::Current { .. })
    }
    pub(super) fn observe(&self, id: &str) -> Observed<Option<ThreadObservation>> {
        let value = self.threads.get(id).map(|t| ThreadObservation::decode(t));
        match self.link {
            Link::Current { epoch } => Observed::Current { epoch, value },
            Link::Offline { epoch } | Link::Syncing { epoch } if value.is_some() => {
                Observed::Stale { epoch, value }
            }
            _ => Observed::Unavailable,
        }
    }
    pub(super) fn thread(&self, id: &str) -> Option<Value> {
        self.threads.get(id).map(|t| (**t).clone())
    }
    pub(super) fn project(&self, id: &str) -> Option<&Value> {
        self.projects.get(id).map(|p| &**p)
    }
}
