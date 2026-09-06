mod support;

fn main() -> avalonia::Result<()> {
    support::sample_app::run(|scope, model, converters| {
        scope.mount_rust_dynamic_vm_window_with_converters(model, converters)
    })
}
