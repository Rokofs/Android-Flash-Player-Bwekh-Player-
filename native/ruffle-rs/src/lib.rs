mod audio;
mod custom_event;
mod java;
mod keycodes;
mod navigator;
mod trace;

use custom_event::RuffleEvent;

use jni::{
    errors::ThrowRuntimeExAndDefault,
    jni_sig, jni_str,
    objects::{JObject, JString},
    sys::{self, jint, jobject},
    Env, EnvUnowned, JavaVM,
};
use keycodes::{android_key_event_to_ruffle_key_descriptor, key_tag_to_key_descriptor};
use std::any::Any;
use std::rc::Rc;
use std::sync::mpsc::Sender;
use std::sync::{mpsc, MutexGuard};
use std::time::Duration;
use std::{
    panic,
    sync::{Arc, Mutex},
    thread,
    time::Instant,
};
use wgpu::rwh::{AndroidDisplayHandle, HasWindowHandle, RawDisplayHandle};

use android_activity::input::{InputEvent, KeyAction, MotionAction};
use android_activity::{AndroidApp, AndroidAppWaker, InputStatus, MainEvent, PollEvent};
use backtrace::Backtrace;
use jni::objects::JClass;

use audio::AudioTrackBackend;
use url::Url;

use ruffle_common::duration::FloatDuration;
use ruffle_core::{
    backend::navigator::OwnedFuture,
    events::{LogicalKey, MouseButton, PlayerEvent},
    tag_utils::SwfMovieData,
    Player, PlayerBuilder, ViewportDimensions,
};
use ruffle_frontend_utils::backends::storage::DiskStorageBackend;
use ruffle_frontend_utils::content::PlayingContent;
use ruffle_frontend_utils::{
    backends::navigator::{ExternalNavigatorBackend, FutureSpawner},
    content::ContentDescriptor,
};

use crate::navigator::AndroidNavigatorInterface;
use crate::trace::FileLogBackend;
use java::JavaInterface;
use ruffle_render::quality::StageQuality;
use ruffle_render_wgpu::{backend::WgpuRenderBackend, target::SwapChainTarget};

/// A unique identifier for a given `Player` instance.
/// Used to track which player any currently executing future is bound to.
#[derive(Copy, Clone, Eq, PartialEq)]
struct PlayerId(i64);

impl PlayerId {
    fn new() -> Self {
        use std::sync::atomic::{AtomicI64, Ordering};

        static NEXT: AtomicI64 = AtomicI64::new(0);
        let id = NEXT.fetch_add(1, Ordering::Relaxed);
        assert!(id >= 0, "PlayerId overflowed!");
        Self(id)
    }
}

/// A `Player`-bound future that is currently running.
pub struct PlayerRunnable(async_task::Runnable<PlayerId>);

/// Represents a current Player and any associated state with that player,
/// which may be lost when this Player is closed (dropped)
struct ActivePlayer {
    id: PlayerId,
    player: Arc<Mutex<Player>>,
}

#[derive(Clone)]
pub struct EventSender {
    sender: Sender<RuffleEvent>,
    waker: AndroidAppWaker,
}

impl EventSender {
    pub fn send(&self, event: RuffleEvent) {
        if self.sender.send(event).is_ok() {
            self.waker.wake();
        }
    }
}

/// A bare-bones executor that schedules tasks on the winit event loop.
struct AndroidExecutor {
    event_loop: EventSender,
    player_id: PlayerId,
}

impl<E: std::error::Error + 'static> FutureSpawner<E> for AndroidExecutor {
    fn spawn(&self, future: OwnedFuture<(), E>) {
        // Discard any errors.
        let future = async {
            if let Err(e) = future.await {
                tracing::error!("Async error: {}", e);
            }
        };

        let event_loop = self.event_loop.clone();
        let scheduler = move |task| {
            let event = RuffleEvent::TaskPoll(PlayerRunnable(task));
            event_loop.send(event)
        };

        let (runnable, task) = async_task::Builder::new()
            .metadata(self.player_id)
            .spawn_local(|_| future, scheduler);

        // The future should run in the background.
        task.detach();
        // Immediately schedule the future to be polled for the first time.
        runnable.schedule();
    }
}

#[tokio::main]
async fn run(app: AndroidApp) {
    let mut perf = Perf::new();
    // Bwekh: the size the game is drawn at (render resolution), None = the window's
    let mut render_dims: Option<(u32, u32)> = None;
    let mut last_frame_time = Instant::now();
    let mut next_frame_time = Some(Instant::now());
    let mut quit = false;
    let (sender, receiver) = mpsc::channel::<RuffleEvent>();
    let mut native_window: Option<ndk::native_window::NativeWindow> = None;
    let mut playerbox: Option<ActivePlayer> = None;
    let sender = EventSender {
        sender,
        waker: app.create_waker(),
    };

    log::info!("Starting event loop...");
    let vm = unsafe { JavaVM::from_raw(app.vm_as_ptr() as *mut sys::JavaVM) };
    // This is a global reference, so it can only be borrowed, not wrapped as a local one.
    let activity_raw = app.activity_as_ptr() as jobject;

    let (trace_output, android_storage_dir) = vm
        .attach_current_thread(|env| -> jni::errors::Result<_> {
            let activity = unsafe { env.as_cast_raw::<JObject>(&activity_raw) }?;
            let trace_output = JavaInterface::get_trace_output(env, &activity);
            let android_storage_dir = JavaInterface::get_android_data_storage_dir(env, &activity);
            let _ = unsafe {
                env.set_rust_field(&*activity, jni_str!("eventLoopHandle"), sender.clone())
            };
            Ok((trace_output, android_storage_dir))
        })
        .expect("JNI calls on the main thread must succeed");

    while !quit {
        let mut needs_redraw = false;
        app.poll_events(
            Some(
                next_frame_time
                    .and_then(|next| next.checked_duration_since(last_frame_time))
                    .unwrap_or_else(|| Duration::from_millis(100)),
            ),
            |event| {
                match event {
                    PollEvent::Main(event) => match event {
                        // Bwekh: the game's process may be ended in the background (it
                        // is killed when the game closes): write save games out now
                        MainEvent::Pause | MainEvent::SaveState { .. } => {
                            if let Some(player) = playerbox.as_ref() {
                                if let Ok(mut player_lock) = player.player.try_lock() {
                                    player_lock.flush_shared_objects();
                                }
                            }
                        }
                        MainEvent::Destroy => {
                            if let Some(player) = playerbox.as_ref() {
                                let mut player_lock = player.player.lock().unwrap();
                                player_lock.flush_shared_objects();
                            }
                            quit = true;
                        }
                        MainEvent::WindowResized { .. } => {
                            if let Some(player) = playerbox.as_ref() {
                                let mut player_lock = player.player.lock().unwrap();
                                let window = native_window
                                    .as_ref()
                                    .expect("native_window should be Some for a WindowResized");
                                log::info!(
                                    "WindowResized: {} x {}",
                                    window.width(),
                                    window.height()
                                );
                                let viewport_scale_factor = app
                                    .config()
                                    .density()
                                    .map(|dpi| dpi as f64 / 160.0)
                                    .unwrap_or(1.0);
                                if let Some(d) = apply_render_size(&app, window) {
                                    render_dims = Some(d);
                                }
                                let (w, h) = render_dims
                                    .unwrap_or((window.width() as u32, window.height() as u32));
                                let dimensions = ViewportDimensions {
                                    width: w,
                                    height: h,
                                    scale_factor: viewport_scale_factor,
                                };
                                player_lock.set_viewport_dimensions(dimensions);
                                needs_redraw = true;
                            }
                        }
                        MainEvent::Resume { .. } => {
                            if let Some(player) = playerbox.as_ref() {
                                if let Some(window) = native_window.as_ref() {
                                    // [NA] For some reason we can get negative sizes during a resume...
                                    if window.width() > 0 && window.height() > 0 {
                                        unsafe {
                                            let mut player = player
                                                .player
                                                .lock()
                                                .unwrap();

                                            let renderer = <dyn Any>::downcast_mut::<WgpuRenderBackend<SwapChainTarget>>(
                                                player.renderer_mut(),
                                            )
                                            .unwrap();

                                            renderer.recreate_surface_unsafe(
                                                wgpu::SurfaceTargetUnsafe::RawHandle {
                                                    raw_display_handle:
                                                        Some(RawDisplayHandle::Android(
                                                            AndroidDisplayHandle::new(),
                                                        )),
                                                    raw_window_handle: window
                                                        .window_handle()
                                                        .unwrap()
                                                        .into(),
                                                },
                                                (window.width() as u32, window.height() as u32),
                                            )
                                            .unwrap();
                                        }
                                        // Bwekh: wgpu put the window back to full size
                                        if let Some((w, h)) = apply_render_size(&app, window) {
                                            render_dims = Some((w, h));
                                            let mut player = player.player.lock().unwrap();
                                            let scale_factor = app
                                                .config()
                                                .density()
                                                .map(|dpi| dpi as f64 / 160.0)
                                                .unwrap_or(1.0);
                                            player.set_viewport_dimensions(ViewportDimensions {
                                                width: w,
                                                height: h,
                                                scale_factor,
                                            });
                                        }
                                    }
                                }
                            }
                        }
                        MainEvent::InitWindow { .. } => {
                            native_window = app.native_window();
                            let window = native_window
                                .as_ref()
                                .expect("native_window should be Some after InitWindow");
                            let viewport_scale_factor = app
                                .config()
                                .density()
                                .map(|dpi| dpi as f64 / 160.0)
                                .unwrap_or(1.0);
                            let dimensions = ViewportDimensions {
                                width: window.width() as u32,
                                height: window.height() as u32,
                                scale_factor: viewport_scale_factor,
                            };
                            log::info!(
                                "Init window: {} x {} (is existing: {})",
                                window.width(),
                                window.height(),
                                playerbox.is_some()
                            );

                            if let Some(activeplayer) = &playerbox {
                                let mut player_lock = activeplayer.player.lock().unwrap();
                                unsafe {
                                    let renderer = <dyn Any>::downcast_mut::<WgpuRenderBackend<SwapChainTarget>>(
                                        player_lock.renderer_mut(),
                                    )
                                    .unwrap();

                                    renderer.recreate_surface_unsafe(
                                        wgpu::SurfaceTargetUnsafe::RawHandle {
                                            raw_display_handle: Some(RawDisplayHandle::Android(
                                                AndroidDisplayHandle::new(),
                                            )),
                                            raw_window_handle: window
                                                .window_handle()
                                                .unwrap()
                                                .into(),
                                        },
                                        (window.width() as u32, window.height() as u32),
                                    )
                                    .unwrap();
                                }
                                if let Some((w, h)) = apply_render_size(&app, window) {
                                    render_dims = Some((w, h));
                                    player_lock.set_viewport_dimensions(ViewportDimensions {
                                        width: w,
                                        height: h,
                                        scale_factor: viewport_scale_factor,
                                    });
                                }
                                player_lock.set_is_playing(true);
                            } else {
                                let renderer = unsafe {
                                    // TODO: make this take an Arc<Window> instead?
                                    match WgpuRenderBackend::for_window_unsafe(
                                        wgpu::SurfaceTargetUnsafe::RawHandle {
                                            raw_display_handle: Some(RawDisplayHandle::Android(
                                                AndroidDisplayHandle::new(),
                                            )),
                                            raw_window_handle: window
                                                .window_handle()
                                                .unwrap()
                                                .into(),
                                        },
                                        (dimensions.width, dimensions.height),
                                        wgpu::Backends::GL,
                                        wgpu::PowerPreference::HighPerformance,
                                        None,
                                    ) {
                                        Ok(r) => r,
                                        Err(e) => {
                                            // Bwekh: no usable OpenGL ES 3 here: the app plays it with
                                            // its own engine instead
                                            let msg = format!("graphics: {e}");
                                            log::error!("{msg}");
                                            let _ = with_activity(&app, |env, activity| {
                                                if let Ok(js) = env.new_string(msg) {
                                                    let _ = env.call_method(
                                                        activity,
                                                        jni_str!("fail"),
                                                        jni_sig!("(Ljava/lang/String;)V"),
                                                        &[(&js).into()],
                                                    );
                                                }
                                            });
                                            quit = true;
                                            return;
                                        }
                                    }
                                };
                                let (url, bytes) = with_activity(&app, |env, activity| {
                                    (
                                        JavaInterface::get_swf_uri(env, activity),
                                        JavaInterface::get_swf_bytes(env, activity),
                                    )
                                })
                                .unwrap();
                                // Bwekh: the SWF's own file:// address, so files next to it load
                                let movie_url = Url::parse(&url)
                                    .unwrap_or_else(|_| Url::parse("file://movie.swf").unwrap());
                                let player_id = PlayerId::new();

                                let future_spawner = AndroidExecutor {
                                    event_loop: sender.clone(),
                                    player_id,
                                };

                                let navigator = ExternalNavigatorBackend::new(
                                    movie_url.clone(),
                                    None,
                                    None,
                                    future_spawner,
                                    None,
                                    true,
                                    Default::default(),
                                    ruffle_core::backend::navigator::SocketMode::Allow,
                                    Rc::new(PlayingContent::DirectFile(ContentDescriptor::new_remote(movie_url))),
                                    AndroidNavigatorInterface,
                                );

                                playerbox = Some(ActivePlayer {
                                    id: player_id,
                                    player: PlayerBuilder::new()
                                            .with_renderer(renderer)
                                            .with_audio(AudioTrackBackend::new(vm.clone()))
                                            .with_storage(Box::new(DiskStorageBackend::new(android_storage_dir.clone())))
                                            .with_navigator(navigator)
                                            .with_log(FileLogBackend::new(trace_output.as_deref()))
                                            .with_video(
                                                ruffle_video_software::backend::SoftwareVideoBackend::new(),
                                            )
                                        .build(),
                                    }
                                );

                                let player = &playerbox.as_ref().unwrap().player;
                                let mut player_lock = player.lock().unwrap();

                                if let Some(bytes) = bytes {
                                    let movie = SwfMovieData::from_data(&bytes, url, None, None).unwrap();
                                    player_lock.mutate_with_update_context(|context| {
                                        context.set_root_movie(movie);
                                    });
                                } else {
                                    player_lock.fetch_root_movie(url, Vec::new(), Box::new(|_| {}))
                                }
                                player_lock.set_is_playing(true); // Desktop player will auto-play.

                                player_lock.set_letterbox(ruffle_core::config::Letterbox::On);

                                // Bwekh: the quality from the app's settings (the game may change it)
                                let quality = with_activity(&app, |env, activity| {
                                    java_string(env, activity, jni_str!("getQuality"))
                                })
                                .ok()
                                .flatten()
                                .unwrap_or_default();
                                let quality = match quality.as_str() {
                                    "low" => Some(StageQuality::Low),
                                    "medium" => Some(StageQuality::Medium),
                                    "high" => Some(StageQuality::High),
                                    "best" => Some(StageQuality::Best),
                                    _ => None,
                                };
                                if let Some(q) = quality {
                                    player_lock.set_quality(q);
                                }

                                // Bwekh: draw at the app's render resolution (after wgpu made the
                                // surface: it sets the window back to full size); the screen scales it up
                                let applied = apply_render_size(&app, window);
                                if applied.is_some() {
                                    render_dims = applied;
                                }
                                let dimensions = match applied {
                                    Some((w, h)) => ViewportDimensions {
                                        width: w,
                                        height: h,
                                        scale_factor: viewport_scale_factor,
                                    },
                                    None => dimensions,
                                };
                                player_lock.set_viewport_dimensions(dimensions);

                                last_frame_time = Instant::now();
                                next_frame_time = Some(Instant::now());

                                log::info!("MOVIE STARTED");
                            }
                        }
                        MainEvent::TerminateWindow { .. }  => {
                            let player = &playerbox.as_ref().unwrap().player;
                            let mut player_lock = player.lock().unwrap();
                            player_lock.set_is_playing(false);
                        }
                        MainEvent::InputAvailable => {
                            if let Ok(mut inputs) = app.input_events_iter() {
                                while inputs.next(|input| match input {
                                    InputEvent::MotionEvent(event) => {
                                        let window = native_window.as_ref().unwrap();
                                        let pointer = event.pointer_index();
                                        let pointer = event.pointer_at_index(pointer);
                                        let coords: (i32, i32) = get_loc_in_window(&app);
                                        let mut x = pointer.x() as f64 - coords.0 as f64;
                                        let mut y = pointer.y() as f64 - coords.1 as f64;
                                        let view_size = get_view_size(&app).unwrap();
                                        // (into the size the game is drawn at)
                                        let (dw, dh) = render_dims
                                            .unwrap_or((window.width() as u32, window.height() as u32));
                                        x = x * dw as f64 / view_size.0 as f64;
                                        y = y * dh as f64 / view_size.1 as f64;
                                        let ruffle_event = match event.action() {
                                            MotionAction::Down | MotionAction::PointerDown | MotionAction::ButtonPress => {
                                                PlayerEvent::MouseDown {
                                                    x,
                                                    y,
                                                    button: MouseButton::Left, // TODO
                                                    index: None, // TODO
                                                }
                                            }
                                            MotionAction::Up | MotionAction::PointerUp | MotionAction::ButtonRelease => {
                                                PlayerEvent::MouseUp {
                                                    x,
                                                    y,
                                                    button: MouseButton::Left, // TODO
                                                }
                                            }
                                            MotionAction::Move => PlayerEvent::MouseMove { x, y },
                                            _ => return InputStatus::Unhandled,
                                        };

                                        if let Some(player) = playerbox.as_ref() {
                                            player
                                                .player
                                                .lock()
                                                .unwrap()
                                                .handle_event(ruffle_event);
                                        }

                                        InputStatus::Handled
                                    }
                                    InputEvent::KeyEvent(event) => {
                                        if let Some(player) = playerbox.as_ref() {
                                            let Some(key_descriptor) =
                                                android_key_event_to_ruffle_key_descriptor(event)
                                            else {
                                                return InputStatus::Unhandled;
                                            };
                                            let down;
                                            let ruffle_event = match event.action() {
                                                KeyAction::Down => {
                                                    down = true;
                                                    PlayerEvent::KeyDown {
                                                        key: key_descriptor,
                                                    }
                                                }
                                                KeyAction::Up => {
                                                    down = false;
                                                    PlayerEvent::KeyUp { key: key_descriptor }
                                                }
                                                _ => return InputStatus::Unhandled,
                                            };
                                            player
                                                .player
                                                .lock()
                                                .unwrap()
                                                .handle_event(ruffle_event);

                                            // TODO: Use `KeyEvent.unicode_char` when it's available:
                                            // https://github.com/rust-mobile/android-activity/issues/183
                                            if down {
                                                if let LogicalKey::Character(c) = key_descriptor.logical_key {
                                                    let event = PlayerEvent::TextInput { codepoint: c };
                                                    player.player.lock().unwrap().handle_event(event);
                                                }
                                            };

                                            needs_redraw = true;
                                        }

                                        InputStatus::Handled
                                    }
                                    _ => InputStatus::Unhandled,
                                }) {}
                            }
                        }
                        _ => {} // Something else happened but it's probably not important for now.
                    },
                    PollEvent::Wake => {} // A task tried to wake us, we'll recv it below
                    PollEvent::Timeout => {} // No events happened, we'll tick as normal below
                    _ => {}               // Unknown future event
                }
            },
        );

        match receiver.try_recv() {
            Err(_) => {}
            Ok(RuffleEvent::TaskPoll(task)) => {
                // Only run the task if it matches our current player;
                // otherwise it is stale, and should be cancelled (which
                // happens implicitly on drop).
                if let Some(player) = playerbox.as_ref() {
                    if *task.0.metadata() == player.id {
                        task.0.run();
                    }
                }
            }
            Ok(RuffleEvent::VirtualKeyEvent {
                down,
                key_descriptor,
            }) => {
                if let Some(player) = playerbox.as_ref() {
                    let event = if down {
                        PlayerEvent::KeyDown {
                            key: key_descriptor,
                        }
                    } else {
                        PlayerEvent::KeyUp {
                            key: key_descriptor,
                        }
                    };
                    player.player.lock().unwrap().handle_event(event);

                    if down {
                        // TODO: Add shift/capslock and pass in uppercase characters accordingly
                        if let LogicalKey::Character(c) = key_descriptor.logical_key {
                            let event = PlayerEvent::TextInput { codepoint: c };
                            player.player.lock().unwrap().handle_event(event);
                        }
                    }
                }
            }
            Ok(RuffleEvent::SetPlaying(playing)) => {
                if let Some(player) = playerbox.as_ref() {
                    player.player.lock().unwrap().set_is_playing(playing);
                }
            }
            Ok(RuffleEvent::RunContextMenuCallback(index)) => {
                if let Some(player) = playerbox.as_ref() {
                    player
                        .player
                        .lock()
                        .unwrap()
                        .run_context_menu_callback(index);
                }
            }
            Ok(RuffleEvent::ClearContextMenu) => {
                if let Some(player) = playerbox.as_ref() {
                    player.player.lock().unwrap().clear_custom_menu_items();
                }
            }
            Ok(RuffleEvent::RequestContextMenu) => {
                if let Some(player) = playerbox.as_ref() {
                    log::warn!("preparing context menu!");
                    let items = player.player.lock().unwrap().prepare_context_menu();
                    with_activity(&app, |env, activity| {
                        JavaInterface::show_context_menu(env, activity, &items)
                    })
                    .unwrap();
                }
            }
        }

        let new_time = Instant::now();
        let dt = new_time.duration_since(last_frame_time).as_micros();
        if dt > 0 {
            last_frame_time = new_time;
            if let Some(player) = playerbox.as_ref() {
                if let Ok(mut player) = player.player.lock() {
                    let t0 = Instant::now();
                    player.tick(FloatDuration::from_millis(dt as f64 / 1000.0));
                    perf.tick_us += t0.elapsed().as_micros();
                    next_frame_time = Some(new_time + player.time_til_next_frame());
                    needs_redraw = player.needs_render();
                }
            } else {
                next_frame_time = None;
            }
        }

        if needs_redraw {
            if let Some(player) = playerbox.as_ref() {
                if let Ok(mut player) = player.player.lock() {
                    let t0 = Instant::now();
                    player.render();
                    perf.render_us += t0.elapsed().as_micros();
                    perf.frames += 1;
                }
            }
        }

        // Bwekh: where the time goes, every 3 s, for the app's log
        let since = perf.start.elapsed();
        if since >= Duration::from_secs(3) {
            if playerbox.is_some() {
                let secs = since.as_secs_f64();
                let size = match (render_dims, native_window.as_ref()) {
                    (Some((w, h)), _) => format!("{w}x{h}"),
                    (None, Some(win)) => format!("{}x{}", win.width(), win.height()),
                    _ => String::new(),
                };
                let quality = playerbox
                    .as_ref()
                    .and_then(|p| p.player.lock().ok().map(|mut p| format!("{:?}", p.quality())))
                    .unwrap_or_default();
                let line = format!(
                    "{:.1} fps, game code {} ms/s, drawing {} ms/s, {} {}",
                    perf.frames as f64 / secs,
                    (perf.tick_us as f64 / 1000.0 / secs).round(),
                    (perf.render_us as f64 / 1000.0 / secs).round(),
                    size,
                    quality
                );
                let _ = with_activity(&app, |env, activity| {
                    if let Ok(js) = env.new_string(line) {
                        let _ = env.call_method(
                            activity,
                            jni_str!("perf"),
                            jni_sig!("(Ljava/lang/String;)V"),
                            &[(&js).into()],
                        );
                    }
                });
            }
            perf = Perf::new();
        }
    }

    let _ = vm.attach_current_thread(|env| -> jni::errors::Result<()> {
        let activity = unsafe { env.as_cast_raw::<JObject>(&activity_raw) }?;
        // Ensure that we take the EventSender back, or we'll leak it
        let _: jni::errors::Result<EventSender> =
            unsafe { env.take_rust_field(&*activity, jni_str!("eventLoopHandle")) };
        Ok(())
    });
}

#[no_mangle]
#[allow(clippy::missing_safety_doc)]
pub unsafe extern "C" fn Java_rs_ruffle_PlayerActivity_keydown<'local>(
    mut unowned_env: EnvUnowned<'local>,
    this: JObject<'local>,
    key_tag: JString<'local>,
) {
    unowned_env
        .with_env(|env| -> jni::errors::Result<()> {
            let tag = key_tag.try_to_string(env)?;

            let event_loop: MutexGuard<Sender<RuffleEvent>> =
                unsafe { env.get_rust_field(&this, jni_str!("eventLoopHandle")) }?;
            if let Some(desc) = key_tag_to_key_descriptor(&tag) {
                let _ = event_loop.send(RuffleEvent::VirtualKeyEvent {
                    down: true,
                    key_descriptor: desc,
                });
            }
            Ok(())
        })
        .resolve::<ThrowRuntimeExAndDefault>()
}

#[no_mangle]
#[allow(clippy::missing_safety_doc)]
pub unsafe extern "C" fn Java_rs_ruffle_PlayerActivity_keyup<'local>(
    mut unowned_env: EnvUnowned<'local>,
    this: JObject<'local>,
    key_tag: JString<'local>,
) {
    unowned_env
        .with_env(|env| -> jni::errors::Result<()> {
            let tag = key_tag.try_to_string(env)?;

            let event_loop: MutexGuard<Sender<RuffleEvent>> =
                unsafe { env.get_rust_field(&this, jni_str!("eventLoopHandle")) }?;
            if let Some(desc) = key_tag_to_key_descriptor(&tag) {
                let _ = event_loop.send(RuffleEvent::VirtualKeyEvent {
                    down: false,
                    key_descriptor: desc,
                });
            }
            Ok(())
        })
        .resolve::<ThrowRuntimeExAndDefault>()
}

/// Bwekh's on-screen gamepad: a Flash key code (37 = left arrow...) pressed or released.
#[no_mangle]
#[allow(clippy::missing_safety_doc)]
pub unsafe extern "C" fn Java_rs_ruffle_PlayerActivity_keyCode<'local>(
    mut unowned_env: EnvUnowned<'local>,
    this: JObject<'local>,
    code: jint,
    down: jint,
) {
    unowned_env
        .with_env(|env| -> jni::errors::Result<()> {
            let event_loop: MutexGuard<Sender<RuffleEvent>> =
                unsafe { env.get_rust_field(&this, jni_str!("eventLoopHandle")) }?;
            if let Some(desc) = keycodes::flash_key_code_to_key_descriptor(code) {
                let _ = event_loop.send(RuffleEvent::VirtualKeyEvent {
                    down: down != 0,
                    key_descriptor: desc,
                });
            }
            Ok(())
        })
        .resolve::<ThrowRuntimeExAndDefault>()
}

/// Bwekh's pause menu: stop / go on (sound too).
#[no_mangle]
#[allow(clippy::missing_safety_doc)]
pub unsafe extern "C" fn Java_rs_ruffle_PlayerActivity_setPlaying<'local>(
    mut unowned_env: EnvUnowned<'local>,
    this: JObject<'local>,
    playing: jint,
) {
    unowned_env
        .with_env(|env| -> jni::errors::Result<()> {
            let event_loop: MutexGuard<Sender<RuffleEvent>> =
                unsafe { env.get_rust_field(&this, jni_str!("eventLoopHandle")) }?;
            let _ = event_loop.send(RuffleEvent::SetPlaying(playing != 0));
            Ok(())
        })
        .resolve::<ThrowRuntimeExAndDefault>()
}

/// Bwekh: the window's buffers at the app's render height (Settings), same shape as the screen.
/// The compositor scales them to the screen: far fewer pixels for the GPU to draw.
fn apply_render_size(
    app: &AndroidApp,
    window: &ndk::native_window::NativeWindow,
) -> Option<(u32, u32)> {
    let sizes = with_activity(app, |env, activity| {
        let rh = env
            .call_method(activity, jni_str!("getRenderHeight"), jni_sig!("()I"), &[])
            .ok()
            .and_then(|v| v.i().ok())
            .unwrap_or(0);
        let vw = JavaInterface::get_surface_width(env, activity);
        let vh = JavaInterface::get_surface_height(env, activity);
        (rh, vw, vh)
    });
    let Ok((rh, vw, vh)) = sizes else { return None };
    if rh <= 0 || vw <= 0 || vh <= 0 || rh >= vh {
        return None;
    }
    let h = rh & !1;
    let w = ((vw as i64 * h as i64 / vh as i64) as i32) & !1;
    // keep the pixel format wgpu chose
    match window.set_buffers_geometry(w, h, Some(window.format())) {
        Ok(()) => Some((w as u32, h as u32)),
        Err(e) => {
            log::error!("render size {w}x{h} failed: {e}");
            None
        }
    }
}

/// Bwekh: frames and time spent, for the log
struct Perf {
    start: Instant,
    frames: u32,
    tick_us: u128,
    render_us: u128,
}

impl Perf {
    fn new() -> Self {
        Self {
            start: Instant::now(),
            frames: 0,
            tick_us: 0,
            render_us: 0,
        }
    }
}

/// Bwekh: a String-returning, no-argument method of the activity (None if it fails or is null)
fn java_string(env: &mut Env, activity: &JObject, name: &'static jni::strings::JNIStr) -> Option<String> {
    let v = env
        .call_method(activity, name, jni_sig!("()Ljava/lang/String;"), &[])
        .ok()?;
    let obj = v.l().ok()?;
    if obj.is_null() {
        return None;
    }
    let js = unsafe { env.as_cast_unchecked::<JString>(&obj) };
    js.try_to_string(env).ok()
}

/// Attaches the current thread to the JVM and runs `f` with the JNI environment and the activity.
///
/// Note: The activity can't be taken from `ndk_context`, because since android-activity 0.6.1,
/// that holds the `Application` instead.
pub fn with_activity<T>(
    app: &AndroidApp,
    f: impl FnOnce(&mut Env, &JObject) -> T,
) -> jni::errors::Result<T> {
    let vm = unsafe { JavaVM::from_raw(app.vm_as_ptr().cast()) };

    // This is a global reference, so it can only be borrowed, not wrapped as a local one.
    let activity_raw = app.activity_as_ptr() as jobject;

    vm.attach_current_thread(|env| {
        let activity = unsafe { env.as_cast_raw::<JObject>(&activity_raw) }?;
        Ok(f(env, &activity))
    })
}

#[no_mangle]
#[allow(clippy::missing_safety_doc)]
pub unsafe extern "C" fn Java_rs_ruffle_PlayerActivity_requestContextMenu<'local>(
    mut unowned_env: EnvUnowned<'local>,
    this: JObject<'local>,
) {
    unowned_env
        .with_env(|env| -> jni::errors::Result<()> {
            let event_loop: MutexGuard<Sender<RuffleEvent>> =
                unsafe { env.get_rust_field(&this, jni_str!("eventLoopHandle")) }?;
            let _ = event_loop.send(RuffleEvent::RequestContextMenu);
            Ok(())
        })
        .resolve::<ThrowRuntimeExAndDefault>()
}

#[no_mangle]
#[allow(clippy::missing_safety_doc)]
pub unsafe extern "C" fn Java_rs_ruffle_PlayerActivity_runContextMenuCallback<'local>(
    mut unowned_env: EnvUnowned<'local>,
    this: JObject<'local>,
    index: jint,
) {
    unowned_env
        .with_env(|env| -> jni::errors::Result<()> {
            let event_loop: MutexGuard<Sender<RuffleEvent>> =
                unsafe { env.get_rust_field(&this, jni_str!("eventLoopHandle")) }?;
            let _ = event_loop.send(RuffleEvent::RunContextMenuCallback(index as usize));
            Ok(())
        })
        .resolve::<ThrowRuntimeExAndDefault>()
}

#[no_mangle]
#[allow(clippy::missing_safety_doc)]
pub unsafe extern "C" fn Java_rs_ruffle_PlayerActivity_clearContextMenu<'local>(
    mut unowned_env: EnvUnowned<'local>,
    this: JObject<'local>,
) {
    unowned_env
        .with_env(|env| -> jni::errors::Result<()> {
            let event_loop: MutexGuard<Sender<RuffleEvent>> =
                unsafe { env.get_rust_field(&this, jni_str!("eventLoopHandle")) }?;
            let _ = event_loop.send(RuffleEvent::ClearContextMenu);
            Ok(())
        })
        .resolve::<ThrowRuntimeExAndDefault>()
}

#[no_mangle]
#[allow(clippy::missing_safety_doc)]
pub unsafe extern "C" fn Java_rs_ruffle_PlayerActivity_nativeInit<'local>(
    mut unowned_env: EnvUnowned<'local>,
    class: JClass<'local>,
    crash_callback: JObject<'local>,
) {
    unowned_env
        .with_env(|env| -> jni::errors::Result<()> { native_init(env, &class, &crash_callback) })
        .resolve::<ThrowRuntimeExAndDefault>()
}

fn native_init(env: &mut Env, class: &JClass, crash_callback: &JObject) -> jni::errors::Result<()> {
    let crash_callback = env.new_global_ref(crash_callback)?;
    let jvm = env.get_java_vm()?;

    android_logger::init_once(
        android_logger::Config::default()
            .with_max_level(log::LevelFilter::Error)
            .with_tag("ruffle")
            .with_filter(
                android_logger::FilterBuilder::new()
                    .parse("error")
                    .build(),
            ),
    );

    panic::set_hook(Box::new(move |info| {
        let backtrace = Backtrace::new();
        let thread = thread::current();
        let thread = thread.name().unwrap_or("<unnamed>");
        let message = match info.payload().downcast_ref::<&'static str>() {
            Some(s) => *s,
            None => match info.payload().downcast_ref::<String>() {
                Some(s) => &**s,
                None => "Box<Any>",
            },
        };

        let full = match info.location() {
            Some(location) => format!(
                "thread '{}' panicked at '{}': {}:{}\n{:?}",
                thread,
                message,
                location.file(),
                location.line(),
                backtrace
            ),
            None => format!(
                "thread '{}' panicked at '{}'\n{:?}",
                thread, message, backtrace
            ),
        };
        log::error!(target: "panic","{}", full);

        // Any exception already pending on this thread is stashed by the attachment while the
        // callback runs, and re-thrown afterwards, so java will still discover it on their own.
        let result = jvm.attach_current_thread(|env| -> jni::errors::Result<()> {
            let java_message = env.new_string(full)?;
            env.call_method(
                &*crash_callback,
                jni_str!("onCrash"),
                jni_sig!("(Ljava/lang/String;)V"),
                &[(&java_message).into()],
            )?;
            Ok(())
        });
        if let Err(e) = result {
            log::error!(target: "panic", "Failed to report crash to java: {}", e);
        }
    }));

    JavaInterface::init(env, class);
    Ok(())
}

fn get_loc_in_window(app: &AndroidApp) -> (i32, i32) {
    // no worky :(
    //ndk_glue::native_activity().show_soft_input(true);

    with_activity(app, JavaInterface::get_loc_in_window).unwrap()
}

fn get_view_size(app: &AndroidApp) -> Result<(i32, i32), Box<dyn std::error::Error>> {
    let size = with_activity(app, |env, activity| {
        let width = JavaInterface::get_surface_width(env, activity);
        let height = JavaInterface::get_surface_height(env, activity);
        (width, height)
    })?;

    Ok(size)
}

#[no_mangle]
fn android_main(app: AndroidApp) {
    log::info!("Starting android_main...");
    run(app);
}
