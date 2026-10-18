use super::*;

/// The part of T3 the agents use; a fake stands in for it in tests.
pub trait Peer: Send + Sync {
    fn call<'a>(
        &'a self,
        tag: &'a str,
        payload: Value,
    ) -> crate::push::BoxFuture<'a, Result<Value>>;
    fn dispatch<'a>(&'a self, command: &'a Command) -> crate::push::BoxFuture<'a, Dispatched>;
    fn snapshot<'a>(
        &'a self,
        tag: &'a str,
        payload: Value,
    ) -> crate::push::BoxFuture<'a, Result<Value>>;
}

impl Peer for T3 {
    fn call<'a>(
        &'a self,
        tag: &'a str,
        payload: Value,
    ) -> crate::push::BoxFuture<'a, Result<Value>> {
        Box::pin(T3::call(self, tag, payload))
    }
    fn dispatch<'a>(&'a self, command: &'a Command) -> crate::push::BoxFuture<'a, Dispatched> {
        Box::pin(T3::dispatch(self, command))
    }
    fn snapshot<'a>(
        &'a self,
        tag: &'a str,
        payload: Value,
    ) -> crate::push::BoxFuture<'a, Result<Value>> {
        Box::pin(T3::snapshot(self, tag, payload))
    }
}

impl crate::push::Threads for Agents {
    fn last_reply<'a>(&'a self, thread: &'a str) -> crate::push::BoxFuture<'a, Option<String>> {
        Box::pin(async move {
            let client = self.client().await.ok()?;
            let detail = self.thread_detail(&*client, thread).await.ok()?;
            detail["messages"]
                .as_array()?
                .iter()
                .rev()
                .find(|m| m["role"] == "assistant")
                .and_then(|m| m["text"].as_str())
                .map(str::to_string)
        })
    }
    fn question<'a>(&'a self, thread: &'a str) -> crate::push::BoxFuture<'a, Option<String>> {
        Box::pin(async move {
            let client = self.client().await.ok()?;
            let detail = self.thread_detail(&*client, thread).await.ok()?;
            let (_, questions) = Self::pending_question(&detail)?;
            questions.first()?["question"].as_str().map(str::to_string)
        })
    }
    fn current_step<'a>(&'a self, thread: &'a str) -> crate::push::BoxFuture<'a, Option<String>> {
        Box::pin(async move { crate::t3steps::current_step(thread).await.ok().flatten() })
    }
    fn quiet<'a>(&'a self, thread: &'a str) -> crate::push::BoxFuture<'a, bool> {
        Box::pin(async move {
            let Ok(client) = self.client().await else {
                return false;
            };
            let Ok(detail) = self.thread_detail(&*client, thread).await else {
                return false;
            };
            detail["messages"]
                .as_array()
                .into_iter()
                .flatten()
                .rev()
                .find(|m| m["role"] == "user" || m["role"] == "assistant")
                .is_some_and(|m| Note::of(m) == Some(Note::Upkeep))
        })
    }
}
