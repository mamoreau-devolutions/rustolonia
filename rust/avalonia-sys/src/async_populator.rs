//! Rust-side `IAvnAsyncPopulator` implementation for AutoCompleteBox's async
//! population. `async_populator()` builds a ref-counted CCW the NativeAOT host
//! consumes as the managed delegate; the closure receives the search text and a
//! completion reporter whose `complete` slot carries the items back.

use crate::com::{ComInterface, ComPtr, IUnknown};
use crate::generated::{IAvnAsyncPopulator, IAvnAsyncPopulatorCompletion};
use crate::guid::Guid;
use crate::hresult::{self, Result};
use std::ffi::c_void;
use std::panic::{catch_unwind, AssertUnwindSafe};
use std::sync::atomic::{fence, AtomicU32, Ordering};
use std::sync::Mutex;

/// Reports the populated items back to the host: one variant list per request.
pub struct PopulateCompletion {
    ptr: ComPtr<IAvnAsyncPopulatorCompletion>,
}

impl PopulateCompletion {
    /// Reports an empty population result; a populated list crosses through the
    /// host-side variant list adapter the closure builds separately.
    pub fn complete(&self, request_id: i64) -> Result<()> {
        self.ptr.complete(request_id, 0, std::ptr::null_mut())
    }

    pub fn complete_with(&self, request_id: i64, hresult_value: i32) -> Result<()> {
        self.ptr
            .complete(request_id, hresult_value, std::ptr::null_mut())
    }
}

type AsyncPopulatorCallback =
    Box<dyn FnMut(i64, *const u16, PopulateCompletion) -> Result<()> + Send>;

#[repr(C)]
struct AsyncPopulatorVtbl {
    query_interface: unsafe extern "system" fn(*mut IUnknown, *const Guid, *mut *mut c_void) -> i32,
    add_ref: unsafe extern "system" fn(*mut IUnknown) -> u32,
    release: unsafe extern "system" fn(*mut IUnknown) -> u32,
    begin_populate: unsafe extern "system" fn(
        *mut IAvnAsyncPopulator,
        i64,
        *mut IAvnAsyncPopulatorCompletion,
        *const u16,
    ) -> i32,
}

#[repr(C)]
struct AsyncPopulatorObject {
    vtbl: *const AsyncPopulatorVtbl,
    ref_count: AtomicU32,
    callback: Mutex<Option<AsyncPopulatorCallback>>,
}

/// Builds an `IAvnAsyncPopulator` from a Rust closure receiving the request id,
/// the borrowed search text, and a completion reporter.
pub fn async_populator(
    callback: impl FnMut(i64, *const u16, PopulateCompletion) -> Result<()> + Send + 'static,
) -> AsyncPopulator {
    let object = Box::into_raw(Box::new(AsyncPopulatorObject {
        vtbl: &ASYNC_POPULATOR_VTBL,
        ref_count: AtomicU32::new(1),
        callback: Mutex::new(Some(Box::new(callback))),
    }));
    AsyncPopulator {
        ptr: unsafe {
            ComPtr::from_raw(object.cast()).expect("Box allocation cannot produce a null pointer")
        },
    }
}

/// An owned handle to a Rust-built populator, safe to hand to the AsyncPopulator
/// setter.
#[derive(Clone, Debug)]
pub struct AsyncPopulator {
    ptr: ComPtr<IAvnAsyncPopulator>,
}

impl AsyncPopulator {
    pub fn as_com_ptr(&self) -> &ComPtr<IAvnAsyncPopulator> {
        &self.ptr
    }
}

fn invoke_callback(
    lock: &Mutex<Option<AsyncPopulatorCallback>>,
    request_id: i64,
    search: *const u16,
    completion: &mut PopulateCompletion,
) -> i32 {
    let callback = {
        let mut slot = match lock.lock() {
            Ok(slot) => slot,
            Err(_) => return hresult::E_FAIL,
        };
        match slot.take() {
            Some(callback) => callback,
            None => return hresult::E_FAIL,
        }
    };
    let mut callback = callback;
    let result = catch_unwind(AssertUnwindSafe(|| {
        // The callback borrows the completion; the PopulateCompletion handle it
        // receives clones the ComPtr, so the host-owned reference is preserved.
        let reporter = PopulateCompletion {
            ptr: completion.ptr.clone(),
        };
        callback(request_id, search, reporter)
    }));
    if let Ok(mut slot) = lock.lock() {
        *slot = Some(callback);
    }
    match result {
        Ok(Ok(())) => hresult::S_OK,
        Ok(Err(error)) => error.0,
        Err(_) => hresult::E_FAIL,
    }
}

unsafe extern "system" fn shared_query_interface(
    this: *mut IUnknown,
    iid: *const Guid,
    result: *mut *mut c_void,
) -> i32 {
    if iid.is_null() || result.is_null() {
        return hresult::E_POINTER;
    }
    unsafe {
        *result = std::ptr::null_mut();
        if *iid != Guid::IUNKNOWN && *iid != IAvnAsyncPopulator::IID {
            return hresult::E_NOINTERFACE;
        }
        *result = this.cast();
        hresult::S_OK
    }
}

unsafe extern "system" fn async_populator_query_interface(
    this: *mut IUnknown,
    iid: *const Guid,
    result: *mut *mut c_void,
) -> i32 {
    let hr = shared_query_interface(this, iid, result);
    if hr == 0 {
        async_populator_add_ref(this);
    }
    hr
}

unsafe extern "system" fn async_populator_add_ref(this: *mut IUnknown) -> u32 {
    let object = this.cast::<AsyncPopulatorObject>();
    (*object).ref_count.fetch_add(1, Ordering::Relaxed) + 1
}

unsafe extern "system" fn async_populator_release(this: *mut IUnknown) -> u32 {
    let object = this.cast::<AsyncPopulatorObject>();
    let remaining = (*object).ref_count.fetch_sub(1, Ordering::Release) - 1;
    if remaining == 0 {
        fence(Ordering::Acquire);
        drop(Box::from_raw(object));
    }
    remaining
}

unsafe extern "system" fn async_populator_begin_populate(
    this: *mut IAvnAsyncPopulator,
    request_id: i64,
    completion: *mut IAvnAsyncPopulatorCompletion,
    search: *const u16,
) -> i32 {
    if completion.is_null() {
        return hresult::E_POINTER;
    }
    let object = this.cast::<AsyncPopulatorObject>();
    let completion = unsafe { ComPtr::from_raw(completion) };
    let Some(completion) = completion else {
        return hresult::E_POINTER;
    };
    let mut completion = PopulateCompletion { ptr: completion };
    invoke_callback(&(*object).callback, request_id, search, &mut completion)
}

#[rustfmt::skip]
static ASYNC_POPULATOR_VTBL: AsyncPopulatorVtbl = AsyncPopulatorVtbl {
    query_interface: async_populator_query_interface,
    add_ref: async_populator_add_ref,
    release: async_populator_release,
    begin_populate: async_populator_begin_populate,
};
