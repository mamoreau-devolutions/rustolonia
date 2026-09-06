use crate::{Error, Result};
use avalonia_sys as sys;
use std::future::Future;
use std::marker::PhantomData;
use std::pin::Pin;
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::{Arc, Mutex};
use std::task::{Context, Poll, Wake, Waker};

#[derive(Debug)]
pub enum AsyncValue {
    None,
    Boolean(bool),
    Integer(i64),
    Double(f64),
    String(Option<String>),
}

#[derive(Debug)]
pub(crate) struct AsyncFailure {
    pub(crate) hresult: i32,
    pub(crate) message: String,
}

/// The shared, executor-neutral half of every host-started operation: exactly
/// one result, plus the waker registered by whichever executor is polling.
#[derive(Debug)]
pub(crate) struct CompletionSlot<T> {
    result: Option<std::result::Result<T, AsyncFailure>>,
    waker: Option<Waker>,
}

impl<T> Default for CompletionSlot<T> {
    fn default() -> Self {
        Self {
            result: None,
            waker: None,
        }
    }
}

impl<T> CompletionSlot<T> {
    /// Records the single completion. A second completion is rejected with
    /// `E_FAIL` instead of overwriting the first, so a misbehaving host cannot
    /// resolve the same operation twice.
    pub(crate) fn publish(
        state: &Arc<Mutex<Self>>,
        result: std::result::Result<T, AsyncFailure>,
    ) -> sys::Result<()> {
        let waker = {
            let mut state = state.lock().expect("async operation state lock poisoned");
            if state.result.is_some() {
                return Err(sys::Error(sys::E_FAIL));
            }
            state.result = Some(result);
            state.waker.take()
        };
        if let Some(waker) = waker {
            waker.wake();
        }
        Ok(())
    }

    pub(crate) fn poll(state: &Arc<Mutex<Self>>, context: &mut Context<'_>) -> Poll<Result<T>> {
        let mut state = state.lock().expect("async operation state lock poisoned");
        match state.result.take() {
            Some(Ok(value)) => Poll::Ready(Ok(value)),
            Some(Err(error)) => Poll::Ready(Err(Error::Async {
                hresult: error.hresult,
                message: error.message,
            })),
            None => {
                state.waker = Some(context.waker().clone());
                Poll::Pending
            }
        }
    }

    pub(crate) fn is_pending(state: &Arc<Mutex<Self>>) -> bool {
        state
            .lock()
            .expect("async operation state lock poisoned")
            .result
            .is_none()
    }
}

pub struct AsyncOperation<T> {
    application: sys::ComPtr<sys::IAvnApplication>,
    operation_id: i64,
    _completion: sys::ComPtr<sys::IAvnAsyncCompletion>,
    state: Arc<Mutex<CompletionSlot<AsyncValue>>>,
    decode: fn(AsyncValue) -> Result<T>,
    _result: PhantomData<T>,
}

impl<T> AsyncOperation<T> {
    pub(crate) fn start(
        application: sys::ComPtr<sys::IAvnApplication>,
        start: impl FnOnce(&sys::ComPtr<sys::IAvnAsyncCompletion>) -> sys::Result<i64>,
        decode: fn(AsyncValue) -> Result<T>,
    ) -> Result<Self> {
        let state = Arc::new(Mutex::new(CompletionSlot::default()));
        let completion_state = state.clone();
        let completion = sys::async_completion(move |arguments| {
            CompletionSlot::publish(&completion_state, decode_completion(arguments))
        });
        let operation_id = start(&completion)?;
        Ok(Self {
            application,
            operation_id,
            _completion: completion,
            state,
            decode,
            _result: PhantomData,
        })
    }
}

impl<T> Future for AsyncOperation<T> {
    type Output = Result<T>;

    fn poll(self: Pin<&mut Self>, context: &mut Context<'_>) -> Poll<Self::Output> {
        match CompletionSlot::poll(&self.state, context) {
            Poll::Ready(Ok(value)) => Poll::Ready((self.decode)(value)),
            Poll::Ready(Err(error)) => Poll::Ready(Err(error)),
            Poll::Pending => Poll::Pending,
        }
    }
}

impl<T> Drop for AsyncOperation<T> {
    fn drop(&mut self) {
        if CompletionSlot::is_pending(&self.state) {
            let _ = self.application.cancel_async_operation(self.operation_id);
        }
    }
}

pub(crate) fn decode_none(value: AsyncValue) -> Result<()> {
    match value {
        AsyncValue::None => Ok(()),
        _ => Err(Error::InvalidAsyncValue),
    }
}

pub(crate) fn decode_string(value: AsyncValue) -> Result<Option<String>> {
    match value {
        AsyncValue::String(value) => Ok(value),
        _ => Err(Error::InvalidAsyncValue),
    }
}

fn decode_completion(
    arguments: &sys::AsyncCompletionArgs,
) -> std::result::Result<AsyncValue, AsyncFailure> {
    if arguments.hresult < 0 {
        return Err(AsyncFailure {
            hresult: arguments.hresult,
            message: arguments
                .error
                .clone()
                .unwrap_or_else(|| format!("async operation failed: 0x{:08X}", arguments.hresult)),
        });
    }
    Ok(match arguments.value_kind {
        0 => AsyncValue::None,
        1 => AsyncValue::Boolean(arguments.integer_value != 0),
        2 => AsyncValue::Integer(arguments.integer_value),
        3 => AsyncValue::Double(arguments.double_value),
        4 => AsyncValue::String(arguments.string_value.clone()),
        _ => {
            return Err(AsyncFailure {
                hresult: sys::E_FAIL,
                message: format!("invalid async value kind {}", arguments.value_kind),
            });
        }
    })
}

pub(crate) struct ScopedTask {
    future: Mutex<Option<Pin<Box<dyn Future<Output = ()> + Send>>>>,
    dispatcher: sys::ComPtr<sys::IAvnDispatcher>,
    scheduled: AtomicBool,
}

impl ScopedTask {
    pub(crate) fn spawn(
        dispatcher: sys::ComPtr<sys::IAvnDispatcher>,
        future: impl Future<Output = ()> + Send + 'static,
    ) -> Result<Arc<Self>> {
        let task = Arc::new(Self {
            future: Mutex::new(Some(Box::pin(future))),
            dispatcher,
            scheduled: AtomicBool::new(false),
        });
        task.clone().schedule()?;
        Ok(task)
    }

    pub(crate) fn cancel(&self) {
        self.future
            .lock()
            .expect("scoped task lock poisoned")
            .take();
    }

    fn schedule(self: Arc<Self>) -> Result<()> {
        if self.scheduled.swap(true, Ordering::AcqRel) {
            return Ok(());
        }
        let dispatcher = self.dispatcher.clone();
        let task = self.clone();
        let action = sys::action(move || {
            task.poll();
            Ok(())
        });
        dispatcher.post(&action)?;
        Ok(())
    }

    fn poll(self: Arc<Self>) {
        self.scheduled.store(false, Ordering::Release);
        let future = self
            .future
            .lock()
            .expect("scoped task lock poisoned")
            .take();
        let Some(mut future) = future else {
            return;
        };
        let waker = Waker::from(self.clone());
        let mut context = Context::from_waker(&waker);
        if future.as_mut().poll(&mut context).is_pending() {
            *self.future.lock().expect("scoped task lock poisoned") = Some(future);
        }
    }
}

impl Wake for ScopedTask {
    fn wake(self: Arc<Self>) {
        let _ = self.schedule();
    }
}
