//! Sound through android.media.AudioTrack (Java, every Android version): Ruffle's mixer fills
//! 16-bit stereo blocks on a thread of its own, which writes them to the track.

use jni::objects::JValue;
use jni::{jni_sig, jni_str, JavaVM};
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::Arc;
use std::thread::JoinHandle;
use std::time::Duration;

pub const SAMPLE_RATE: i32 = 44100;
const FRAMES: usize = 1024;

pub struct AudioThread {
    playing: Arc<AtomicBool>,
    stop: Arc<AtomicBool>,
    thread: Option<JoinHandle<()>>,
}

impl AudioThread {
    pub fn start<F>(vm: JavaVM, mut mix: F) -> Self
    where
        F: FnMut(&mut [f32]) + Send + 'static,
    {
        let playing = Arc::new(AtomicBool::new(false));
        let stop = Arc::new(AtomicBool::new(false));
        let (p, s) = (playing.clone(), stop.clone());
        let thread = std::thread::Builder::new()
            .name("ruffle-audio".into())
            .spawn(move || {
                let result = vm.attach_current_thread(|env| -> jni::errors::Result<()> {
                    let class = env.find_class(jni_str!("android/media/AudioTrack"))?;
                    // STREAM_MUSIC 3, CHANNEL_OUT_STEREO 12, ENCODING_PCM_16BIT 2, MODE_STREAM 1
                    let min = env
                        .call_static_method(
                            &class,
                            jni_str!("getMinBufferSize"),
                            jni_sig!("(III)I"),
                            &[JValue::Int(SAMPLE_RATE), JValue::Int(12), JValue::Int(2)],
                        )?
                        .i()?;
                    let bytes = std::cmp::max(min, (FRAMES * 4 * 2) as i32);
                    let track = env.new_object(
                        &class,
                        jni_sig!("(IIIIII)V"),
                        &[
                            JValue::Int(3),
                            JValue::Int(SAMPLE_RATE),
                            JValue::Int(12),
                            JValue::Int(2),
                            JValue::Int(bytes),
                            JValue::Int(1),
                        ],
                    )?;
                    let arr = env.new_short_array(FRAMES * 2)?;
                    let mut fbuf = vec![0f32; FRAMES * 2];
                    let mut sbuf = vec![0i16; FRAMES * 2];
                    let mut started = false;
                    while !s.load(Ordering::Relaxed) {
                        if !p.load(Ordering::Relaxed) {
                            if started {
                                env.call_method(&track, jni_str!("pause"), jni_sig!("()V"), &[])?;
                                started = false;
                            }
                            std::thread::sleep(Duration::from_millis(20));
                            continue;
                        }
                        if !started {
                            env.call_method(&track, jni_str!("play"), jni_sig!("()V"), &[])?;
                            started = true;
                        }
                        for v in fbuf.iter_mut() {
                            *v = 0.0;
                        }
                        mix(&mut fbuf);
                        for (o, i) in sbuf.iter_mut().zip(fbuf.iter()) {
                            *o = (i.clamp(-1.0, 1.0) * 32767.0) as i16;
                        }
                        arr.set_region(env, 0, &sbuf)?;
                        // blocks until there's room: this paces the loop
                        env.call_method(
                            &track,
                            jni_str!("write"),
                            jni_sig!("([SII)I"),
                            &[JValue::Object(&arr), JValue::Int(0), JValue::Int(sbuf.len() as i32)],
                        )?;
                    }
                    let _ = env.call_method(&track, jni_str!("stop"), jni_sig!("()V"), &[]);
                    let _ = env.call_method(&track, jni_str!("release"), jni_sig!("()V"), &[]);
                    Ok(())
                });
                if let Err(e) = result {
                    log_error(&format!("AudioTrack failed: {e}"));
                }
            })
            .ok();
        Self { playing, stop, thread }
    }

    pub fn set_playing(&self, on: bool) {
        self.playing.store(on, Ordering::Relaxed);
    }
}

impl Drop for AudioThread {
    fn drop(&mut self) {
        self.stop.store(true, Ordering::Relaxed);
        if let Some(t) = self.thread.take() {
            let _ = t.join();
        }
    }
}

fn log_error(s: &str) {
    log::error!("{s}");
}

use ruffle_core::backend::audio::{
    swf, AudioBackend, AudioMixer, DecodeError, RegisterError, SoundHandle, SoundInstanceHandle,
    SoundStreamInfo, SoundTransform,
};
use ruffle_core::impl_audio_mixer_backend;

/// Ruffle's sound on any Android version (AAudio needs Android 8): the mixer, played by an
/// AudioTrack on its own thread.
pub struct AudioTrackBackend {
    mixer: AudioMixer,
    output: AudioThread,
}

impl AudioTrackBackend {
    pub fn new(vm: JavaVM) -> Self {
        let mixer = AudioMixer::new(2, SAMPLE_RATE as u32);
        let proxy = mixer.proxy();
        let output = AudioThread::start(vm, move |buf: &mut [f32]| proxy.mix(buf));
        Self { mixer, output }
    }
}

impl AudioBackend for AudioTrackBackend {
    impl_audio_mixer_backend!(mixer);

    fn play(&mut self) {
        self.output.set_playing(true);
    }

    fn pause(&mut self) {
        self.output.set_playing(false);
    }
}
